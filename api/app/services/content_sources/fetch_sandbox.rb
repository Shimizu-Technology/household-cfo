# frozen_string_literal: true

require "etc"
require "json"
require "tempfile"
require "timeout"

module ContentSources
  class FetchSandbox
    MAX_RUNTIME = 20.seconds
    MAX_RSS_BYTES = 192 * 1024 * 1024
    Result = Data.define(:tempfile, :filename, :content_type, :byte_size, :checksum_sha256, :redirect_count) do
      def path
        tempfile.path
      end

      def close!
        tempfile.close!
      end
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
        reader.close
        Process.setpgrp
        apply_resource_limit
        payload = begin
          result = Timeout.timeout(MAX_RUNTIME) { PinnedHttpsFetcher.new.call(url, output_path: output_path) }
          {
            ok: true,
            result: result.to_h.except(:path)
          }
        rescue ContentSources::Error => error
          { ok: false, code: error.code }
        rescue StandardError
          { ok: false, code: "url_fetch_failed" }
        end
        writer.write(JSON.generate(payload))
        writer.close
        exit! 0
      end
    end

    def supervise(pid, reader)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_RUNTIME
      loop do
        waited = Process.waitpid(pid, Process::WNOHANG)
        break if waited
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline || resident_bytes(pid) > MAX_RSS_BYTES
          terminate(pid)
          Process.wait(pid)
          raise Error, "url_fetch_failed"
        end
        sleep 0.02
      end
      payload = JSON.parse(reader.read)
      raise Error, payload.fetch("code") unless payload.fetch("ok")

      payload.fetch("result")
    rescue JSON::ParserError, EOFError, TypeError, ArgumentError
      raise Error, "url_fetch_failed"
    end

    def apply_resource_limit
      Process.setrlimit(:AS, MAX_RSS_BYTES, MAX_RSS_BYTES)
    rescue ArgumentError, Errno::EINVAL, NotImplementedError
      nil
    end

    def resident_bytes(pid)
      output = IO.popen([ "/bin/ps", "-o", "rss=", "-p", pid.to_s ], err: File::NULL, &:read)
      return 0 if output.strip.empty?

      Integer(output.strip, 10) * 1024
    rescue ArgumentError, SystemCallError
      MAX_RSS_BYTES + 1
    end

    def terminate(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
