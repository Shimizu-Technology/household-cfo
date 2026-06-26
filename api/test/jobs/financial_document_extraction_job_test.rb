require "test_helper"

class FinancialDocumentExtractionJobTest < ActiveJob::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_doc_extract_user",
      email: "doc-extract@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Extraction Household")
    @household.household_memberships.create!(user: @user, role: "owner")
    @document_import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      document_kind: "statement",
      status: "uploaded",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 100,
      s3_key: "household-cfo/test/statement.pdf"
    )
  end

  test "successful extraction creates review items and attempt audit" do
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: Date.new(2026, 6, 20),
          period_start_on: Date.new(2026, 6, 1),
          period_end_on: Date.new(2026, 6, 30),
          summary: "June statement found groceries and a Visa balance.",
          confidence: "high",
          warnings: [ "Review categories before applying." ],
          items: [
            {
              target_type: "expense_item",
              label: "Groceries",
              amount_cents: 825_00,
              cadence: "monthly",
              stack_key: "discretionary",
              confidence: "medium",
              evidence: "Grocery transactions totaled $825.",
              metadata: {}
            },
            {
              target_type: "debt",
              label: "Visa",
              balance_cents: 4_820_00,
              payment_cents: 150_00,
              debt_type: "credit_card",
              confidence: "high",
              evidence: "Statement ending balance.",
              metadata: {}
            }
          ]
        },
        error: nil,
        metadata: { usage: { "total_tokens" => 123 }, finish_reason: "stop" }
      )
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "needs_review", @document_import.status
    assert_equal "June statement found groceries and a Visa balance.", @document_import.extracted_summary
    assert_equal Date.new(2026, 6, 30), @document_import.period_end_on
    assert_equal 2, @document_import.items.count
    assert_equal "succeeded", @document_import.attempts.last.status
    assert_equal({ "total_tokens" => 123 }, @document_import.attempts.last.metadata.fetch("usage"))
  end

  test "failed extraction marks import failed and records attempt" do
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(success: false, data: nil, error: "model unavailable", metadata: { status_code: 503 })
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "failed", @document_import.status
    assert_equal "model unavailable", @document_import.extraction_error
    assert_equal "failed", @document_import.attempts.last.status
    assert_equal "model unavailable", @document_import.attempts.last.error
    assert_equal 503, @document_import.attempts.last.metadata.fetch("status_code")
  end

  private

  def fake_extractor(result)
    Object.new.tap do |object|
      object.define_singleton_method(:model) { "test/model" }
      object.define_singleton_method(:call) { |_document_import| result }
    end
  end

  def with_extractor_stub(extractor)
    singleton = class << FinancialDocuments::Extractor; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |*| extractor }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end
end
