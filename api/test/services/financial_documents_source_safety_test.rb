require "test_helper"
require "tempfile"
require "zip"

# Hostile fixtures are generated in-test; nothing large is committed.
class FinancialDocumentsSourceSafetyTest < ActiveJob::TestCase
  SourceSafety = FinancialDocuments::SourceSafety
  CONTENT_TYPES_XML = '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'.freeze

  test "accepts ordinary Office files including the published budget template" do
    template = Rails.root.join("..", "web", "public", "household-cfo-budget-template.xlsx").to_s
    assert SourceSafety.check_ooxml!(template)

    with_zip("[Content_Types].xml" => CONTENT_TYPES_XML, "word/document.xml" => document_xml("Monthly income 6200")) do |path|
      assert SourceSafety.check_ooxml!(path)
    end
  end

  test "rejects a highly compressed zip bomb from the central directory alone" do
    with_zip("[Content_Types].xml" => CONTENT_TYPES_XML, "word/document.xml" => "0" * 4.megabytes) do |path|
      assert_operator File.size(path), :<, 64.kilobytes
      assert_unreadable("ooxml_unsafe") { SourceSafety.check_ooxml!(path) }
    end
  end

  test "rejects archives with too many entries" do
    entries = (SourceSafety::OOXML_MAX_ENTRIES + 1).times.to_h { |index| [ "xl/part#{index}.xml", "<x/>" ] }
    with_zip(entries) do |path|
      assert_unreadable("ooxml_too_many_entries") { SourceSafety.check_ooxml!(path) }
    end
  end

  test "rejects archives whose declared expansion exceeds the total cap" do
    with_forged_directory(name: "xl/worksheets/sheet1.xml", compressed: 1.megabyte, uncompressed: SourceSafety::OOXML_MAX_UNCOMPRESSED_BYTES + 1) do |path|
      assert_unreadable("ooxml_too_large_uncompressed") { SourceSafety.check_ooxml!(path) }
    end
  end

  test "rejects encrypted and path-traversal entries" do
    with_forged_directory(name: "word/document.xml", flags: 0x1) do |path|
      assert_unreadable("ooxml_unsafe") { SourceSafety.check_ooxml!(path) }
    end
    with_zip("[Content_Types].xml" => CONTENT_TYPES_XML, "../outside.xml" => "<x/>") do |path|
      assert_unreadable("ooxml_unsafe") { SourceSafety.check_ooxml!(path) }
    end
  end

  test "rejects Office files above the structured upload limit before reading them" do
    with_bytes(".xlsx", "PK".b + ("\0".b * FinancialDocuments::UploadLimits::STRUCTURED_SOURCE_MAX_BYTES)) do |path|
      assert_unreadable("ooxml_file_too_large") { SourceSafety.check_ooxml!(path) }
    end
  end

  test "stops a private download as soon as it passes the size cap" do
    written = 0
    with_download_stub(->(_key, io) { 5.times { io.write("x" * 1_024); written += 1 }; true }) do
      Tempfile.create([ "capped-download", ".pdf" ], binmode: true) do |file|
        assert_unreadable("source_too_large") { SourceSafety.download("key", file, max_bytes: 2_048) }
        assert_operator file.size, :<=, 2_048
      end
    end
    assert_equal 2, written
  end

  test "rejects an oversized PDF without starting the sandbox" do
    with_bytes(".pdf", "%PDF-1.4\n".b + ("0".b * FinancialDocuments::UploadLimits::INLINE_SOURCE_MAX_BYTES)) do |path|
      with_sandbox_stub(->(*) { raise "sandbox must not start" }) do
        assert_unreadable("source_too_large") { SourceSafety.pdf_page_count!(path) }
        refute SourceSafety.pdf_text_readable?(path, max_pages: 60, max_runs: 60_000)
      end
    end
  end

  test "counts PDF pages in the sandbox and reports too many pages for the text probe" do
    with_pdf_pages(3) do |path|
      assert_equal 3, SourceSafety.pdf_page_count!(path)
      assert SourceSafety.pdf_text_readable?(path, max_pages: 60, max_runs: 60_000)
    end
    with_pdf_pages(61) do |path|
      assert_equal 61, SourceSafety.pdf_page_count!(path)
      refute SourceSafety.pdf_text_readable?(path, max_pages: 60, max_runs: 60_000)
    end
    with_bytes(".pdf", "not a pdf") do |path|
      assert_unreadable("pdf_invalid") { SourceSafety.pdf_page_count!(path) }
    end
  end

  test "a PDF that exhausts the sandbox kills only the worker" do
    with_hostile_worker('value = "x" * 50_000_000; sleep 30; STDOUT.write(value.byteslice(0, 1))') do |sandbox|
      with_sandbox_stub(->(*) { sandbox }) do
        with_pdf_pages(1) do |path|
          assert_unreadable("pdf_resource_limit") { SourceSafety.pdf_page_count!(path) }
          refute SourceSafety.pdf_text_readable?(path, max_pages: 60, max_runs: 60_000)
        end
      end
    end
  end

  test "a zip-bomb workbook fails its import calmly and leaves Reprocess available" do
    document_import = create_import!(filename: "budget.xlsx", content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", document_kind: "spreadsheet")
    bomb = zip_bytes("[Content_Types].xml" => CONTENT_TYPES_XML, "xl/workbook.xml" => "<workbook/>", "xl/worksheets/sheet1.xml" => "0" * 4.megabytes)
    roo_opened = false
    original_new = Roo::Excelx.method(:new)
    Roo::Excelx.define_singleton_method(:new) { |*args, **kwargs| roo_opened = true; original_new.call(*args, **kwargs) }

    with_s3_stubs(configured?: true, download_to_io: ->(_key, io) { io.write(bomb); true }) do
      FinancialDocumentExtractionJob.perform_now(document_import.id)
    end

    document_import.reload
    refute roo_opened
    assert_equal "failed", document_import.status
    assert_equal SourceSafety::MESSAGE, document_import.extraction_error
    assert_equal "failed", document_import.attempts.sole.status
    assert_equal "extraction_failed", document_import.extraction_dispatch.error_code
  ensure
    Roo::Excelx.singleton_class.send(:remove_method, :new) if Roo::Excelx.singleton_class.method_defined?(:new, false)
  end

  test "a PDF that exhausts the sandbox fails its import calmly" do
    document_import = create_import!
    with_hostile_worker("sleep 30") do |sandbox|
      with_sandbox_stub(->(*) { sandbox }) do
        with_pdf_pages(1) do |pdf_path|
          with_s3_stubs(configured?: true, download_to_io: ->(_key, io) { io.write(File.binread(pdf_path)); true }) do
            FinancialDocumentExtractionJob.perform_now(document_import.id)
          end
        end
      end
    end

    document_import.reload
    assert_equal "failed", document_import.status
    assert_equal SourceSafety::MESSAGE, document_import.extraction_error
  end

  private

  def assert_unreadable(reason)
    error = assert_raises(SourceSafety::Unreadable) { yield }
    assert_equal reason, error.reason
    assert_equal SourceSafety::MESSAGE, error.message
  end

  def document_xml(text)
    %(<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>#{text}</w:t></w:r></w:p></w:body></w:document>)
  end

  def zip_bytes(entries)
    buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      entries.each do |name, value|
        zip.put_next_entry(name)
        zip.write(value)
      end
    end
    buffer.string
  end

  def with_zip(entries, &block)
    with_bytes(".docx", zip_bytes(entries), &block)
  end

  # A central directory alone is all OoxmlGuard reads, so a forged one can
  # declare sizes and flags no real archive needs to contain.
  def with_forged_directory(name:, flags: 0, compressed: 10, uncompressed: 10, &block)
    header = [ 0x02014b50, 20, 20, flags, 8, 0, 0, 0, compressed, uncompressed, name.bytesize, 0, 0, 0, 0, 0, 0 ].pack("VvvvvvvVVVvvvvvVV") + name.b
    eocd = [ 0x06054b50, 0, 0, 1, 1, header.bytesize, 0, 0 ].pack("VvvvvVVv")
    with_bytes(".docx", header + eocd, &block)
  end

  def with_bytes(extension, bytes)
    file = Tempfile.new([ "source-safety", extension ])
    file.binmode
    file.write(bytes)
    file.close
    yield file.path
  ensure
    file&.close!
  end

  def with_pdf_pages(count)
    file = Tempfile.new([ "source-safety", ".pdf" ])
    file.close
    pdf = CombinePDF.new
    count.times { pdf << CombinePDF.create_page }
    pdf.save(file.path)
    yield file.path
  ensure
    file&.close!
  end

  def with_hostile_worker(body)
    script = Tempfile.new([ "hostile-pdf-worker", ".rb" ])
    script.write(body)
    script.close
    yield ContentSources::PdfSandbox.new(script_path: script.path, timeout_seconds: 0.5, max_rss_bytes: 32 * 1024 * 1024)
  ensure
    script&.close!
  end

  def with_sandbox_stub(replacement, &block)
    with_singleton_stub(SourceSafety, :pdf_sandbox, replacement, &block)
  end

  def with_download_stub(replacement, &block)
    with_singleton_stub(S3Service, :download_to_io, replacement, &block)
  end

  def with_s3_stubs(stubs, &block)
    stubs.to_a.reverse.reduce(block) do |inner, (method_name, replacement)|
      -> { with_singleton_stub(S3Service, method_name, replacement.respond_to?(:call) ? replacement : ->(*) { replacement }, &inner) }
    end.call
  end

  def with_singleton_stub(target, method_name, replacement)
    singleton = target.singleton_class
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    singleton.define_method(method_name, original) if original
  end

  def create_import!(attributes = {})
    user = User.create!(clerk_id: "clerk_source_safety_#{SecureRandom.hex(4)}", email: "source-safety-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Source Safety Household")
    household.household_memberships.create!(user: user, role: "owner")
    FinancialDocumentImport.create!({
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 100,
      s3_key: "household-cfo/test/source-safety"
    }.merge(attributes))
  end
end
