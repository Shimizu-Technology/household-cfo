require "test_helper"

class FinancialDocumentsUploadLimitsTest < ActiveSupport::TestCase
  test "limits inline image and PDF sources to extractor capacity" do
    assert_equal 12.megabytes, FinancialDocuments::UploadLimits.max_bytes(filename: "statement.pdf", content_type: "application/pdf")
    assert_equal 12.megabytes, FinancialDocuments::UploadLimits.max_bytes(filename: "receipt.png", content_type: "image/png")
    assert_match(/max 12 MB/, FinancialDocuments::UploadLimits.validation_error(byte_size: 12.megabytes + 1, filename: "receipt.jpg", content_type: "image/jpeg"))
  end

  test "keeps structured spreadsheet and Word sources at twenty MiB" do
    assert_equal 20.megabytes, FinancialDocuments::UploadLimits.max_bytes(filename: "budget.csv", content_type: "text/csv")
    assert_equal 20.megabytes, FinancialDocuments::UploadLimits.max_bytes(
      filename: "plan.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    assert_nil FinancialDocuments::UploadLimits.validation_error(byte_size: 20.megabytes, filename: "budget.xlsx", content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  test "uses the stricter limit when either extension or media type is inline" do
    assert_equal 12.megabytes, FinancialDocuments::UploadLimits.max_bytes(filename: "misnamed.csv", content_type: "application/pdf")
    assert_equal 12.megabytes, FinancialDocuments::UploadLimits.max_bytes(filename: "misnamed.pdf", content_type: "text/csv")
  end
end
