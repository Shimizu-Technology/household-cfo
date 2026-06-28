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
end
