# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class ContentSourcesPdfSandboxTest < ActiveSupport::TestCase
  test "kills a PDF worker that exceeds its wall clock limit" do
    with_worker("sleep 5") do |script|
      sandbox = ContentSources::PdfSandbox.new(script_path: script, timeout_seconds: 0.05)
      assert_error_code { sandbox.call("unused.pdf") }
    end
  end

  test "kills a PDF worker before accepting oversized serialized output" do
    with_worker('STDOUT.write("x" * 10_000)') do |script|
      sandbox = ContentSources::PdfSandbox.new(script_path: script, max_output_bytes: 128)
      assert_error_code { sandbox.call("unused.pdf") }
    end
  end

  test "kills a PDF worker that exceeds the resident-memory budget" do
    with_worker('value = "x" * 20_000_000; sleep 5; STDOUT.write(value.byteslice(0, 1))') do |script|
      sandbox = ContentSources::PdfSandbox.new(script_path: script, max_rss_bytes: 8 * 1024 * 1024)
      assert_error_code { sandbox.call("unused.pdf") }
    end
  end

  test "passes the configured memory budget to the kernel address-space limit" do
    sandbox = ContentSources::PdfSandbox.new(max_rss_bytes: 123_456, kernel_address_space_limit: true)
    reader, writer = IO.pipe

    options = sandbox.send(:spawn_options, writer)

    assert_equal [ 123_456, 123_456 ], options.fetch(:rlimit_as)
    assert_equal [ ContentSources::PdfSandbox::CPU_SECONDS, ContentSources::PdfSandbox::CPU_SECONDS ], options.fetch(:rlimit_cpu)
  ensure
    reader&.close
    writer&.close
  end

  test "keeps the portable RSS watchdog when the platform cannot apply rlimit as" do
    sandbox = ContentSources::PdfSandbox.new(kernel_address_space_limit: false)
    reader, writer = IO.pipe

    refute sandbox.send(:spawn_options, writer).key?(:rlimit_as)
  ensure
    reader&.close
    writer&.close
  end

  test "reads resident pages from proc using the configured portable page size" do
    Dir.mktmpdir("pdf-sandbox-proc") do |root|
      FileUtils.mkdir_p(File.join(root, "4321"))
      File.write(File.join(root, "4321", "statm"), "100 7 2 1 0 0 0\n")
      sandbox = ContentSources::PdfSandbox.new(proc_root: root, page_size: 16_384)

      assert_equal 7 * 16_384, sandbox.send(:resident_bytes, 4321)
    end
  end

  test "falls back to ps when proc status is unavailable" do
    sandbox = ContentSources::PdfSandbox.new(proc_root: "/path/that/does/not/exist")
    sandbox.define_singleton_method(:process_alive?) { |_pid| true }
    sandbox.define_singleton_method(:ps_resident_bytes) { |_pid| 42_000 }

    assert_equal 42_000, sandbox.send(:resident_bytes, 4321)
  end

  test "allows a completed worker to drain its pipe after proc status disappears" do
    sandbox = ContentSources::PdfSandbox.new(proc_root: "/path/that/does/not/exist")
    sandbox.define_singleton_method(:process_alive?) { |_pid| false }

    assert_equal 0, sandbox.send(:resident_bytes, 4321)
  end

  private

  def with_worker(body)
    file = Tempfile.new([ "pdf-sandbox-test", ".rb" ])
    file.write(body)
    file.close
    yield file.path
  ensure
    file&.close!
  end

  def assert_error_code
    error = assert_raises(ContentSources::Error) { yield }
    assert_equal "pdf_resource_limit", error.code
  end
end
