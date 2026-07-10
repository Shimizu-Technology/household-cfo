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
        metadata: {
          usage: { "total_tokens" => 123 },
          finish_reason: "stop",
          extraction_mode: "pdf_batches",
          page_count: 9,
          batch_count: 3
        }
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
    assert_equal "pdf_batches", @document_import.metadata.fetch("extraction_mode")
    assert_equal 9, @document_import.metadata.fetch("extraction_page_count")
    assert_equal 3, @document_import.metadata.fetch("extraction_batch_count")
  end

  test "successful extraction stages transaction drafts with splits and match proposals" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    period = manager.current_period_for(Date.new(2026, 7, 5))
    groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    cigarettes = @household.budget_categories.create!(name: "Cigarettes", stack_key: "discretionary", sort_order: 2)
    existing = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    existing.transaction_splits.create!(budget_category: groceries, amount_cents: 1_357)
    @document_import.update!(document_kind: "receipt", filename: "payless.jpg", content_type: "image/jpeg")
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "receipt",
          document_date: Date.new(2026, 7, 5),
          period_start_on: nil,
          period_end_on: nil,
          summary: "Receipt and statement rows found.",
          confidence: "high",
          warnings: [],
          items: [],
          transaction_drafts: [
            {
              occurred_on: "2026-07-05",
              merchant: "Payless",
              total_amount: 103.42,
              source_type: "receipt",
              confidence: "medium",
              evidence: "Receipt total.",
              splits: [
                { category_name: "Groceries", stack_key: "discretionary", amount: 85.42, notes: "Food lines", confidence: "medium" },
                { category_name: "Cigarettes", stack_key: "discretionary", amount: 18.00, notes: "Tobacco line", confidence: "medium" }
              ]
            },
            {
              occurred_on: "2026-07-05",
              merchant: "Penny Cafe",
              total_amount: 13.57,
              source_type: "statement",
              confidence: "high",
              evidence: "Statement row.",
              splits: [ { category_name: "Groceries", stack_key: "discretionary", amount: 13.57, confidence: "high" } ]
            }
          ]
        },
        error: nil,
        metadata: {}
      )
    )

    assert_no_difference("HouseholdTransaction.count") do
      with_extractor_stub(extractor) do
        FinancialDocumentExtractionJob.perform_now(@document_import.id)
      end
    end

    @document_import.reload
    assert_equal "needs_review", @document_import.status
    assert_equal 2, @document_import.transaction_drafts.count
    payless = @document_import.transaction_drafts.find_by!(merchant: "Payless")
    assert_equal 10_342, payless.total_amount_cents
    assert_equal BigDecimal("0.65"), payless.confidence
    assert_equal [ groceries.id, cigarettes.id ], payless.transaction_draft_splits.order(:id).pluck(:budget_category_id)
    assert_equal [ 8_542, 1_800 ], payless.transaction_draft_splits.order(:id).pluck(:amount_cents)
    assert_equal [ BigDecimal("0.65"), BigDecimal("0.65") ], payless.transaction_draft_splits.order(:id).pluck(:confidence)
    penny = @document_import.transaction_drafts.find_by!(merchant: "Penny Cafe")
    assert_equal 1, penny.transaction_draft_matches.count
    assert_equal existing.id, penny.transaction_draft_matches.first.household_transaction_id
    assert_equal 2, @document_import.metadata.fetch("transaction_draft_count")
    assert_equal 1, @document_import.metadata.fetch("transaction_match_count")
  end

  test "attempt metadata is allowlisted and bounded" do
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: nil,
          period_start_on: nil,
          period_end_on: nil,
          summary: "No actionable values.",
          confidence: "medium",
          warnings: [],
          items: []
        },
        error: nil,
        metadata: {
          usage: { "total_tokens" => 123, "debug_blob" => "x" * 5_000 },
          provider: { "name" => "openrouter-" + ("x" * 500), "raw" => "ignored" },
          finish_reason: "stop",
          raw_response: "ignored"
        }
      )
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    metadata = @document_import.reload.attempts.last.metadata
    assert_equal({ "total_tokens" => 123 }, metadata.fetch("usage"))
    assert_equal "stop", metadata.fetch("finish_reason")
    assert_operator metadata.fetch("provider").length, :<=, FinancialDocumentExtractionJob::ATTEMPT_METADATA_STRING_LENGTH
    assert_not metadata.key?("raw_response")
  end

  test "job schedules stale recheck for imports that are already processing recently" do
    @document_import.update!(status: "processing")
    @document_import.attempts.create!(
      provider: "openrouter",
      model: "test/model",
      status: "processing",
      prompt_version: FinancialDocuments::Extractor::PROMPT_VERSION,
      schema_version: FinancialDocuments::Extractor::SCHEMA_VERSION,
      started_at: Time.current
    )
    extractor_called = false
    extractor = Object.new.tap do |object|
      object.define_singleton_method(:model) { "test/model" }
      object.define_singleton_method(:call) do |_document_import|
        extractor_called = true
        FinancialDocuments::Extractor::Result.new(success: false, data: nil, error: "should not run", metadata: {})
      end
    end

    with_extractor_stub(extractor) do
      assert_no_difference("FinancialDocumentImportAttempt.count") do
        assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ @document_import.id ]) do
          FinancialDocumentExtractionJob.perform_now(@document_import.id)
        end
      end
    end

    assert_equal false, extractor_called
    assert_equal "processing", @document_import.reload.status
  end

  test "job restarts stale processing imports so queue retries can recover" do
    @document_import.update!(status: "processing")
    stale_attempt = @document_import.attempts.create!(
      provider: "openrouter",
      model: "test/model",
      status: "processing",
      prompt_version: FinancialDocuments::Extractor::PROMPT_VERSION,
      schema_version: FinancialDocuments::Extractor::SCHEMA_VERSION,
      started_at: (FinancialDocumentExtractionJob::STALE_PROCESSING_AFTER + 1.minute).ago
    )
    @document_import.update_columns(updated_at: (FinancialDocumentExtractionJob::STALE_PROCESSING_AFTER + 1.minute).ago)
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: nil,
          period_start_on: nil,
          period_end_on: nil,
          summary: "Recovered retry finished.",
          confidence: "medium",
          warnings: [],
          items: []
        },
        error: nil,
        metadata: {}
      )
    )

    with_extractor_stub(extractor) do
      assert_difference("FinancialDocumentImportAttempt.count", 1) do
        FinancialDocumentExtractionJob.perform_now(@document_import.id)
      end
    end

    assert_equal "needs_review", @document_import.reload.status
    assert_equal "failed", stale_attempt.reload.status
    assert_equal true, stale_attempt.metadata.fetch("stalled")
    assert_equal "succeeded", @document_import.attempts.order(:id).last.status
  end

  test "job skips imports that were already processed synchronously" do
    @document_import.update!(status: "needs_review", extracted_summary: "Already read")
    extractor_called = false
    extractor = Object.new.tap do |object|
      object.define_singleton_method(:model) { "test/model" }
      object.define_singleton_method(:call) do |_document_import|
        extractor_called = true
        FinancialDocuments::Extractor::Result.new(success: false, data: nil, error: "should not run", metadata: {})
      end
    end

    with_extractor_stub(extractor) do
      assert_no_difference("FinancialDocumentImportAttempt.count") do
        FinancialDocumentExtractionJob.perform_now(@document_import.id)
      end
    end

    assert_equal false, extractor_called
    assert_equal "needs_review", @document_import.reload.status
    assert_equal "Already read", @document_import.extracted_summary
  end

  test "attempt creation failure does not leave import stuck processing" do
    callback = lambda { |attempt| throw(:abort) if attempt.financial_document_import_id == @document_import.id }
    FinancialDocumentImportAttempt.set_callback(:create, :before, callback)

    assert_no_difference("FinancialDocumentImportAttempt.count") do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "uploaded", @document_import.status
    assert_nil @document_import.processed_at
  ensure
    FinancialDocumentImportAttempt.skip_callback(:create, :before, callback)
  end

  test "failed extraction clears stale successful extraction fields" do
    @document_import.update!(
      extracted_summary: "Old summary",
      document_date: Date.new(2026, 6, 1),
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30),
      metadata: {
        "confidence" => "high",
        "warnings" => [ "old warning" ],
        "extraction_model" => "old/model",
        "last_extracted_at" => "2026-06-01T00:00:00Z",
        "upload_request_id" => "keep-me"
      }
    )
    extractor = fake_extractor(
      FinancialDocuments::Extractor::Result.new(success: false, data: nil, error: "model unavailable", metadata: { status_code: 503 })
    )

    with_extractor_stub(extractor) do
      FinancialDocumentExtractionJob.perform_now(@document_import.id)
    end

    @document_import.reload
    assert_equal "failed", @document_import.status
    assert_nil @document_import.extracted_summary
    assert_nil @document_import.document_date
    assert_nil @document_import.period_start_on
    assert_nil @document_import.period_end_on
    assert_equal "keep-me", @document_import.metadata.fetch("upload_request_id")
    assert_equal true, @document_import.metadata.key?("last_extraction_failed_at")
    assert_not @document_import.metadata.key?("confidence")
    assert_not @document_import.metadata.key?("warnings")
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
