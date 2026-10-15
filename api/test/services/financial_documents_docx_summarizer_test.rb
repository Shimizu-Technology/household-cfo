require "test_helper"
require "zip"

class FinancialDocumentsDocxSummarizerTest < ActiveSupport::TestCase
  test "extracts sanitized paragraph text from docx files" do
    file = Tempfile.new([ "budget-plan", ".docx" ])
    file.close
    Zip::File.open(file.path, create: true) do |zip|
      zip.get_output_stream("[Content_Types].xml") do |stream|
        stream.write <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          </Types>
        XML
      end
      zip.get_output_stream("word/document.xml") do |stream|
        stream.write <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
              <w:p><w:r><w:t>Monthly income: $6,200</w:t></w:r></w:p>
              <w:p><w:r><w:t>Emergency fund &lt;target&gt; is $12,000</w:t></w:r></w:p>
            </w:body>
          </w:document>
        XML
      end
    end

    summary = FinancialDocuments::DocxSummarizer.new(file_path: file.path, filename: "budget-plan.docx").call

    assert_equal "budget-plan.docx", summary.fetch(:filename)
    assert_includes summary.fetch(:text), "Monthly income: $6,200"
    assert_includes summary.fetch(:text), "Emergency fund target is $12,000"
  ensure
    file&.unlink
  end

  test "refuses a zip-bomb document before inflating it" do
    with_docx("word/document.xml" => "0" * 4.megabytes) do |path|
      error = assert_raises(FinancialDocuments::SourceSafety::Unreadable) do
        FinancialDocuments::DocxSummarizer.new(file_path: path, filename: "bomb.docx").call
      end
      assert_equal "ooxml_unsafe", error.reason
    end
  end

  test "refuses too many entries, traversal names and oversized or DTD-bearing XML" do
    many = (FinancialDocuments::SourceSafety::OOXML_MAX_ENTRIES + 1).times.to_h { |index| [ "word/media/part#{index}.xml", "<x/>" ] }
    oversized = "<w:document>#{SecureRandom.alphanumeric(FinancialDocuments::SourceSafety::OOXML_MAX_XML_BYTES)}</w:document>"
    {
      "ooxml_too_many_entries" => many,
      "ooxml_unsafe" => { "../word/document.xml" => "<x/>" },
      "ooxml_entry_too_large" => { "word/document.xml" => oversized }
    }.each do |reason, entries|
      with_docx(entries) do |path|
        error = assert_raises(FinancialDocuments::SourceSafety::Unreadable) do
          FinancialDocuments::DocxSummarizer.new(file_path: path, filename: "hostile.docx").call
        end
        assert_equal reason, error.reason
      end
    end

    with_docx("word/document.xml" => '<!DOCTYPE x [<!ENTITY a "aaaa">]><w:document>&a;</w:document>') do |path|
      error = assert_raises(FinancialDocuments::SourceSafety::Unreadable) do
        FinancialDocuments::DocxSummarizer.new(file_path: path, filename: "entity.docx").call
      end
      assert_equal "ooxml_unsafe", error.reason
    end
  end

  private

  def with_docx(entries)
    file = Tempfile.new([ "hostile", ".docx" ])
    file.close
    Zip::OutputStream.open(file.path) do |zip|
      { "[Content_Types].xml" => "<Types/>" }.merge(entries).each do |name, value|
        zip.put_next_entry(name)
        zip.write(value)
      end
    end
    yield file.path
  ensure
    file&.close!
  end
end
