# frozen_string_literal: true

require "test_helper"
require "tempfile"

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
