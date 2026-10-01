# frozen_string_literal: true

require "json"
require "rbconfig"

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
      script_path: Rails.root.join("lib/content_sources/pdf_sandbox_worker.rb")
    )
      @timeout_seconds = timeout_seconds
      @max_output_bytes = max_output_bytes
      @max_rss_bytes = max_rss_bytes
      @script_path = script_path.to_s
    end

    def call(path)
      reader, writer = IO.pipe
      pid = Process.spawn(
        child_environment, RbConfig.ruby, script_path, path.to_s,
        out: writer, err: File::NULL, pgroup: true,
        rlimit_cpu: [ CPU_SECONDS, CPU_SECONDS ], unsetenv_others: true
      )
      writer.close
      output = read_bounded(reader, pid)
      _waited_pid, status = Process.wait2(pid)
      pid = nil
      raise Error, "pdf_resource_limit" unless status.success?

      payload = JSON.parse(output)
      raise Error, payload.fetch("code", "pdf_invalid") unless payload["ok"] == true
      raise Error, "pdf_invalid" unless payload["pages"].is_a?(Array) && payload["page_count"] == payload["pages"].length

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

    attr_reader :timeout_seconds, :max_output_bytes, :max_rss_bytes, :script_path

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
      output = IO.popen([ "/bin/ps", "-o", "rss=", "-p", pid.to_s ], err: File::NULL, &:read)
      output.to_i * 1024
    rescue SystemCallError
      max_rss_bytes + 1
    end

    def child_environment
      ENV.slice("PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_GEMFILE", "BUNDLE_BIN_PATH", "RUBYOPT", "RUBYLIB")
    end

    def terminate(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
