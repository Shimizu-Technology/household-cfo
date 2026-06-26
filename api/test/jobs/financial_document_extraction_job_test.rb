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

  test "stale extraction success does not overwrite import reset by reprocess" do
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: Date.new(2026, 6, 20),
          period_start_on: Date.new(2026, 6, 1),
          period_end_on: Date.new(2026, 6, 30),
          summary: "Stale result that should not be shown.",
          confidence: "high",
          warnings: [],
          items: [
            {
              target_type: "expense_item",
              label: "Stale groceries",
              amount_cents: 999_00,
              cadence: "monthly",
              stack_key: "discretionary",
              confidence: "medium",
              evidence: "Old extraction result.",
              metadata: {}
            }
          ]
        },
        error: nil,
        metadata: {}
      ),
      before_return: -> { @document_import.reload.update!(status: "uploaded", extraction_error: nil, processed_at: nil) }
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "uploaded", @document_import.status
    assert_nil @document_import.extracted_summary
    assert_empty @document_import.items
    attempt = @document_import.attempts.last
    assert_equal "failed", attempt.status
    assert_match(/superseded/, attempt.error)
    assert_equal true, attempt.metadata.fetch("superseded")
  end

  test "older extraction success does not overwrite a newer active attempt" do
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: Date.new(2026, 6, 20),
          period_start_on: Date.new(2026, 6, 1),
          period_end_on: Date.new(2026, 6, 30),
          summary: "Older result that should not win.",
          confidence: "high",
          warnings: [],
          items: [
            {
              target_type: "expense_item",
              label: "Older result",
              amount_cents: 500_00,
              cadence: "monthly",
              stack_key: "discretionary",
              confidence: "medium",
              evidence: "Old extraction result.",
              metadata: {}
            }
          ]
        },
        error: nil,
        metadata: {}
      ),
      before_return: lambda {
        @document_import.reload.attempts.create!(
          provider: "openrouter",
          model: "test/model",
          status: "processing",
          prompt_version: FinancialDocuments::Extractor::PROMPT_VERSION,
          schema_version: FinancialDocuments::Extractor::SCHEMA_VERSION,
          started_at: Time.current
        )
      }
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "processing", @document_import.status
    assert_empty @document_import.items
    assert_equal 2, @document_import.attempts.count
    assert_equal "failed", @document_import.attempts.order(:id).first.status
    assert_equal "processing", @document_import.attempts.order(:id).last.status
  end

  private

  def fake_extractor(result, before_return: nil)
    Object.new.tap do |object|
      object.define_singleton_method(:model) { "test/model" }
      object.define_singleton_method(:call) do |_document_import|
        before_return&.call
        result
      end
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
