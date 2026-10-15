# frozen_string_literal: true

require "json"
require "rbconfig"
require "etc"

module ContentSources
  class PdfSandbox
    DEFAULT_TIMEOUT_SECONDS = 12
    DEFAULT_MAX_OUTPUT_BYTES = 2 * 1024 * 1024
    ADDRESS_SPACE_BYTES = 384 * 1024 * 1024
    CPU_SECONDS = 8

    def initialize(
      timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
      max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
      max_rss_bytes: ADDRESS_SPACE_BYTES,
      script_path: Rails.root.join("lib/content_sources/pdf_sandbox_worker.rb"),
      proc_root: "/proc",
      page_size: nil,
      kernel_address_space_limit: RUBY_PLATFORM.include?("linux"),
      cpu_seconds: CPU_SECONDS,
      load_paths: nil
    )
      @timeout_seconds = timeout_seconds
      @max_output_bytes = max_output_bytes
      @max_rss_bytes = max_rss_bytes
      @script_path = script_path.to_s
      @proc_root = proc_root.to_s
      @page_size = page_size || system_page_size
      @kernel_address_space_limit = kernel_address_space_limit
      @cpu_seconds = cpu_seconds
      @load_paths = load_paths&.map(&:to_s)
    end

    def call(path)
      payload = run(path)
      raise Error, "pdf_invalid" unless payload["pages"].is_a?(Array) && payload["page_count"] == payload["pages"].length

      payload
    end

    # Runs the worker script against path (plus any extra string arguments)
    # and returns its parsed JSON payload once the worker reports ok.
    def run(path, *args)
      reader, writer = IO.pipe
      pid = Process.spawn(
        child_environment, RbConfig.ruby, *load_path_flags, script_path, path.to_s, *args.map(&:to_s),
        **spawn_options(writer)
      )
      writer.close
      output = read_bounded(reader, pid)
      _waited_pid, status = Process.wait2(pid)
      pid = nil
      raise Error, "pdf_resource_limit" unless status.success?

      payload = JSON.parse(output)
      raise Error, "pdf_invalid" unless payload.is_a?(Hash)
      raise Error, payload.fetch("code", "pdf_invalid") unless payload["ok"] == true

      payload
    rescue JSON::ParserError, KeyError, TypeError
      raise Error, "pdf_invalid"
    rescue Errno::EINVAL, NotImplementedError
      raise Error, "pdf_resource_limit"
    ensure
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      terminate(pid) if pid
    end

    private

    attr_reader :timeout_seconds, :max_output_bytes, :max_rss_bytes, :script_path, :proc_root, :page_size, :kernel_address_space_limit, :cpu_seconds, :load_paths

    def spawn_options(writer)
      options = {
        out: writer,
        err: File::NULL,
        pgroup: true,
        rlimit_cpu: [ cpu_seconds, cpu_seconds ],
        unsetenv_others: true
      }
      options[:rlimit_as] = [ max_rss_bytes, max_rss_bytes ] if kernel_address_space_limit
      options
    end

    def read_bounded(io, pid)
      output = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "pdf_resource_limit" if remaining <= 0
        ready = IO.select([ io ], nil, nil, [ remaining, 0.05 ].min)
        raise Error, "pdf_resource_limit" if resident_bytes(pid) > max_rss_bytes
        next unless ready

        chunk = io.read_nonblock(64 * 1024)
        output << chunk
        raise Error, "pdf_resource_limit" if output.bytesize > max_output_bytes
      rescue IO::WaitReadable
        next
      rescue EOFError
        break
      end
      output
    rescue Error
      terminate(pid)
      Process.wait(pid)
      raise
    end

    def resident_bytes(pid)
      statm_path = File.join(proc_root, pid.to_s, "statm")
      if File.file?(statm_path)
        resident_pages = Integer(File.read(statm_path, 256).split.fetch(1), 10)
        return resident_pages * page_size
      end

      return 0 unless process_alive?(pid)

      ps_resident_bytes(pid)
    rescue ArgumentError, IndexError
      max_rss_bytes + 1
    rescue SystemCallError
      process_alive?(pid) ? ps_resident_bytes(pid) : 0
    end

    def ps_resident_bytes(pid)
      output = IO.popen([ "/bin/ps", "-o", "rss=", "-p", pid.to_s ], err: File::NULL, &:read)
      return 0 if output.strip.empty? && !process_alive?(pid)

      kilobytes = Integer(output.strip, 10)
      kilobytes * 1024
    rescue ArgumentError
      max_rss_bytes + 1
    rescue SystemCallError
      max_rss_bytes + 1
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def system_page_size
      value = Etc.sysconf(Etc::SC_PAGESIZE)
      value.is_a?(Integer) && value.positive? ? value : 4096
    rescue StandardError
      4096
    end

    # With explicit load_paths the worker loads exactly the parent's gem
    # versions via -I and never re-runs Bundler, so it does not depend on the
    # host's Bundler configuration being visible to the child.
    def child_environment
      return ENV.slice("PATH", "GEM_HOME", "GEM_PATH") if load_paths

      ENV.slice("PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_GEMFILE", "BUNDLE_BIN_PATH", "RUBYOPT", "RUBYLIB")
    end

    def load_path_flags
      Array(load_paths).flat_map { |path| [ "-I", path ] }
    end

    def terminate(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
