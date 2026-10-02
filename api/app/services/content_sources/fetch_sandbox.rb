# frozen_string_literal: true

require "etc"
require "json"
require "tempfile"
require "timeout"

module ContentSources
  class FetchSandbox
    MAX_RUNTIME = 20.seconds
    MAX_RSS_GROWTH_BYTES = 192 * 1024 * 1024
    Result = Data.define(:tempfile, :filename, :content_type, :byte_size, :checksum_sha256, :redirect_count) do
      def path
        tempfile.path
      end

      def close!
        tempfile.close!
      end
    end

    def initialize(
      proc_root: "/proc", page_size: nil, ps_path: "/bin/ps",
      kernel_address_space_limit: RUBY_PLATFORM.include?("linux")
    )
      @proc_root = proc_root.to_s
      @page_size = page_size || system_page_size
      @ps_path = ps_path.to_s
      @kernel_address_space_limit = kernel_address_space_limit
    end

    def call(url)
      output = Tempfile.new([ "content-source-url", ".snapshot" ])
      output.binmode
      output.close
      reader, writer = IO.pipe
      pid = fork_child(url, output.path, reader, writer)
      writer.close
      metadata = supervise(pid, reader)
      Result.new(**metadata.transform_keys(&:to_sym).merge(tempfile: output))
    rescue ContentSources::Error
      output&.close!
      raise
    rescue StandardError
      output&.close!
      raise Error, "url_fetch_failed"
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    private

    def fork_child(url, output_path, reader, writer)
      Process.fork do
        begin
          reader.close
          Process.setpgrp
          ENV.replace(ENV.slice("PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_GEMFILE", "BUNDLE_BIN_PATH", "RUBYOPT", "RUBYLIB", "SSL_CERT_FILE", "SSL_CERT_DIR"))
          apply_resource_limit
          payload = begin
            result = Timeout.timeout(MAX_RUNTIME) { PinnedHttpsFetcher.new.call(url, output_path: output_path) }
            {
              ok: true,
              result: result.to_h.except(:path)
            }
          rescue ContentSources::Error => error
            { ok: false, code: error.code }
          rescue StandardError, NoMemoryError
            { ok: false, code: "url_fetch_failed" }
          end
          writer.write(JSON.generate(payload))
        ensure
          writer.close unless writer.closed?
          exit! 0
        end
      end
    end

    def supervise(pid, reader)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_RUNTIME
      baseline_rss = resident_bytes(pid)
      loop do
        waited = Process.waitpid(pid, Process::WNOHANG)
        break if waited
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline ||
            rss_limit_exceeded?(baseline_rss, resident_bytes(pid))
          terminate(pid)
          Process.wait(pid)
          raise Error, "url_fetch_failed"
        end
        sleep 0.05
      end
      payload = JSON.parse(reader.read)
      raise Error, payload.fetch("code") unless payload.fetch("ok")

      payload.fetch("result")
    rescue JSON::ParserError, EOFError, TypeError, ArgumentError
      raise Error, "url_fetch_failed"
    end

    def apply_resource_limit
      return unless @kernel_address_space_limit

      limit = current_address_space_bytes
      return unless limit

      Process.setrlimit(:AS, limit + MAX_RSS_GROWTH_BYTES, limit + MAX_RSS_GROWTH_BYTES)
    rescue ArgumentError, Errno::EINVAL, NotImplementedError
      nil
    end

    def rss_limit_exceeded?(baseline_rss, current_rss)
      current_rss > baseline_rss + MAX_RSS_GROWTH_BYTES
    end

    def resident_bytes(pid)
      statm_path = File.join(@proc_root, Integer(pid).to_s, "statm")
      if File.file?(statm_path)
        resident_pages = Integer(File.read(statm_path, 256).split.fetch(1), 10)
        return resident_pages * @page_size
      end

      return 0 unless process_alive?(pid)

      ps_resident_bytes(pid)
    rescue ArgumentError, IndexError
      MAX_RSS_BYTES + 1
    rescue SystemCallError
      process_alive?(pid) ? ps_resident_bytes(pid) : 0
    end

    def ps_resident_bytes(pid)
      output = IO.popen([ @ps_path, "-o", "rss=", "-p", pid.to_s ], err: File::NULL, &:read)
      return 0 if output.strip.empty? && !process_alive?(pid)

      Integer(output.strip, 10) * 1024
    rescue Errno::ENOENT, Errno::ESRCH
      0
    rescue ArgumentError, SystemCallError
      MAX_RSS_BYTES + 1
    end

    def current_address_space_bytes
      statm_path = File.join(@proc_root, "self", "statm")
      return nil unless File.file?(statm_path)

      Integer(File.read(statm_path, 256).split.fetch(0), 10) * @page_size
    rescue ArgumentError, IndexError, SystemCallError
      nil
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

    def terminate(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
