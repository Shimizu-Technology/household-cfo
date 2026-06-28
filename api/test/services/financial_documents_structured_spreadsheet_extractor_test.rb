require "test_helper"

class FinancialDocumentsStructuredSpreadsheetExtractorTest < ActiveSupport::TestCase
  test "extracts Household CFO Excel template rows without AI" do
    file_path = Rails.root.join("..", "web", "public", "household-cfo-budget-template.xlsx")

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file_path.to_s, filename: "household-cfo-budget-template.xlsx").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    assert_equal 10, items.length
    assert_equal "job", items.find { |item| item[:label] == "Primary salary" }.fetch(:source_type)
    assert_equal "non_discretionary", items.find { |item| item[:label] == "Rent or mortgage" }.fetch(:stack_key)
    assert_equal "sinking_expected", items.find { |item| item[:label] == "Car maintenance fund" }.fetch(:stack_key)
    assert_equal "sinking_unexpected", items.find { |item| item[:label] == "Medical and family buffer" }.fetch(:stack_key)
    assert_equal "emergency_fund", items.find { |item| item[:label] == "Emergency fund" }.fetch(:account_type)
    debt = items.find { |item| item[:label] == "Visa card" }
    assert_equal "credit_card", debt.fetch(:debt_type)
    assert_equal 3400_00, debt.fetch(:balance_cents)
    assert_equal 175_00, debt.fetch(:payment_cents)
  end

  test "skips non-finite spreadsheet amounts without failing whole extraction" do
    file = Tempfile.new([ "budget", ".csv" ])
    file.write("type,label,amount,cadence,category,notes\nexpense_item,Broken formula,NaN,monthly,discretionary,Ignore\nexpense_item,Dining out,420,monthly,discretionary,Valid\n")
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "budget.csv").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    assert_equal 1, items.length
    assert_equal "Dining out", items.first.fetch(:label)
  ensure
    file&.close!
  end

  test "extractor uses structured spreadsheet path without OpenRouter key" do
    user = User.create!(clerk_id: "clerk_structured_extractor_user", email: "structured-extractor@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Structured Extractor Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "uploaded",
      filename: "budget.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "household-cfo/test/budget.csv"
    )

    with_s3_download("type,label,amount,cadence,category,payment,notes\ndebt,Visa card,3400,monthly,credit_card,175,Minimum payment\n") do
      result = FinancialDocuments::Extractor.new(api_key: nil).call(document_import)

      assert result.success?, result.error
      assert_equal "structured_spreadsheet", result.metadata.fetch(:extraction_mode)
      assert_equal 1, result.data.fetch(:items).length
      assert_equal 175_00, result.data.fetch(:items).first.fetch(:payment_cents)
    end
  end

  private

  def with_s3_download(contents)
    singleton = class << S3Service; self; end
    configured_original = singleton.instance_method(:configured?)
    download_original = singleton.instance_method(:download_to_io)
    singleton.define_method(:configured?) { true }
    singleton.define_method(:download_to_io) do |_key, io|
      io.write(contents)
      true
    end
    yield
  ensure
    singleton.send(:remove_method, :configured?) if singleton.method_defined?(:configured?)
    singleton.send(:remove_method, :download_to_io) if singleton.method_defined?(:download_to_io)
    singleton.define_method(:configured?, configured_original)
    singleton.define_method(:download_to_io, download_original)
  end
end
