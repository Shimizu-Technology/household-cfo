require "test_helper"

class HouseholdFinanceDocumentTransactionDraftPersisterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_draft_persister_user",
      email: "draft-persister@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Draft Persister Household")
    @category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    @document_import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      document_kind: "statement",
      status: "processing",
      filename: "statement.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "household-cfo/test/statement.csv"
    )
  end

  test "maps confidence labels to draft and split decimals" do
    payload = {
      occurred_on: "2026-07-05",
      merchant: "Penny Cafe",
      total_amount: "13.57",
      source_type: "statement",
      confidence: "high",
      evidence: "Statement row",
      splits: [
        { amount: "13.57", category_name: "Dining Out", stack_key: "discretionary", notes: "Lunch", confidence: "low" }
      ]
    }

    result = HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, [ payload ]).call

    assert_equal 1, result.fetch(:created_count)
    assert_empty result.fetch(:warnings)
    draft = @document_import.transaction_drafts.find_by!(merchant: "Penny Cafe")
    assert_equal BigDecimal("0.90"), draft.confidence
    assert_equal BigDecimal("0.35"), draft.transaction_draft_splits.first.confidence
  end

  test "rolls back partially-created draft when matcher raises during persistence" do
    payload = {
      occurred_on: "2026-07-05",
      merchant: "Penny Cafe",
      total_amount: "13.57",
      source_type: "statement",
      evidence: "Statement row",
      splits: [
        { amount: "13.57", category_name: "Dining Out", stack_key: "discretionary", notes: "Lunch" }
      ]
    }

    result = nil
    with_failing_matcher do
      result = HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, [ payload ]).call
    end

    assert_equal 0, result.fetch(:created_count)
    assert_equal 0, result.fetch(:match_count)
    assert_match(/Skipped transaction row 1:/, result.fetch(:warnings).join)
    assert_equal 0, @document_import.transaction_drafts.count
    assert_equal 0, TransactionDraftSplit.joins(:transaction_draft).where(transaction_drafts: { financial_document_import_id: @document_import.id }).count
  end

  test "keeps mixed receipt lines unresolved instead of applying the merchant category to every split" do
    groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 2)
    payload = {
      occurred_on: "2026-07-05",
      merchant: "Tita's Demo Market",
      total_amount: "70.25",
      source_type: "receipt",
      confidence: "medium",
      evidence: "Four receipt groups",
      splits: [
        { amount: "42.15", category_name: "Food", notes: "Food items", confidence: "medium" },
        { amount: "13.50", category_name: "Household supplies", notes: "Cleaning products", confidence: "medium" },
        { amount: "11.25", category_name: "Cigarettes", notes: "Tobacco line", confidence: "medium" },
        { amount: "3.35", category_name: "Tax", notes: "Sales tax", confidence: "medium" }
      ]
    }

    result = HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, [ payload ]).call

    assert_equal 1, result.fetch(:created_count)
    assert_empty result.fetch(:warnings)
    splits = @document_import.transaction_drafts.find_by!(merchant: "Tita's Demo Market").transaction_draft_splits.ordered
    assert_equal [ groceries.id, nil, nil, nil ], splits.pluck(:budget_category_id)
    assert_equal %w[matched needs_review needs_review needs_review], splits.map { |split| split.metadata.fetch("category_match_status") }
    assert_equal "Household supplies", splits.second.metadata.fetch("extracted_category_name")
    assert_equal "no_strong_match", splits.second.metadata.fetch("category_match_reason")
  end

  private

  def with_failing_matcher
    singleton = class << HouseholdFinance::TransactionDraftMatcher; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) do |draft|
      Object.new.tap do |matcher|
        matcher.define_singleton_method(:call) do
          TransactionDraftSplit.connection.execute(<<~SQL.squish)
            INSERT INTO transaction_draft_splits (transaction_draft_id, amount_cents, created_at, updated_at)
            VALUES (#{draft.id}, -1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          SQL
        end
      end
    end
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end
end
