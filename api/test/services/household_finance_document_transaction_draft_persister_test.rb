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

  test "statement groceries and fuel default to everyday spending instead of an extracted broad bill label" do
    @household.budget_categories.create!(name: "Fixed essentials", stack_key: "non_discretionary")
    everyday = @household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary")
    payloads = [ "Payless", "Cost-U-Less", "Shell", "Mobil" ].map do |merchant|
      { merchant: merchant, occurred_on: "2026-07-05", total_amount: "35", source_type: "statement",
        splits: [ { amount: "35", category_name: "Fixed essentials", stack_key: "non_discretionary", confidence: "high" } ] }
    end
    result = HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, payloads).call
    assert_equal 4, result[:created_count]
    assert_empty result[:warnings]
    @document_import.transaction_drafts.each do |draft|
      assert_equal everyday.id, draft.budget_category_id, draft.merchant
      split = draft.transaction_draft_splits.sole
      assert_equal everyday.id, split.budget_category_id, draft.merchant
      assert_equal "matched", split.metadata["category_match_status"]
      assert_equal "everyday_spending_default", split.metadata["category_match_reason"]
    end
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

  test "rejects more than the complete transaction cap instead of truncating" do
    payloads = Array.new(HouseholdFinance::DocumentTransactionDraftPersister::MAX_DRAFTS + 1) { {} }

    error = assert_raises(ArgumentError) do
      HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, payloads)
    end

    assert_includes error.message, "more than 500 transaction rows"
    assert_equal 0, @document_import.transaction_drafts.count
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

  def receipt_import
    FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "receipt", status: "processing",
      filename: "receipt.jpg", content_type: "image/jpeg", byte_size: 100, s3_key: "household-cfo/test/receipt.jpg")
  end

  def voucher_receipt(**overrides)
    { occurred_on: "2026-06-23", merchant: "Tasi Demo Home Store", total_amount: 184.88, source_type: "receipt", category_name: "Household",
      evidence: "Home fan 129.99; Shelf kit 54.89; TOTAL $184.88; Voucher / gift card $150.00; Debit card 7302 $34.88; Balance due $0.00",
      warnings: [ "Paid with $150.00 voucher/gift card plus $34.88 on debit card 7302." ],
      splits: [ { amount: 129.99, category_name: "Household", notes: "Home fan" }, { amount: 54.89, category_name: "Dining Out", notes: "Shelf kit" } ] }.merge(overrides)
  end

  test "a receipt partly paid with a voucher proposes only the new money, splits scaled, receipt kept as context" do
    @household.budget_categories.create!(name: "Household", stack_key: "discretionary", sort_order: 2)
    document = receipt_import

    result = HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ voucher_receipt ]).call

    assert_equal 1, result.fetch(:created_count)
    draft = document.transaction_drafts.sole
    assert_equal 3_488, draft.total_amount_cents
    splits = draft.transaction_draft_splits.order(:id)
    # 34.88 * 129.99 / 184.88 = 24.524…, 34.88 * 54.89 / 184.88 = 10.355…: the whole cent goes to the larger remainder.
    assert_equal [ 2_452, 1_036 ], splits.map(&:amount_cents)
    assert_equal [ 12_999, 5_489 ], splits.map { |split| split.metadata["receipt_amount_cents"] }
    assert_equal [ 2_452, 1_036 ], splits.map { |split| split.metadata["new_money_amount_cents"] }
    payment = draft.draft_payload.fetch("receipt_payment")
    assert_equal 18_488, payment.fetch("receipt_total_cents")
    assert_equal 3_488, payment.fetch("new_money_cents")
    assert_equal [ false, true ], payment.fetch("paid_with").map { |tender| tender.fetch("new_money") }

    shown = HouseholdFinance::ReceiptTenders.presentation(draft)
    assert_equal "$150.00 was paid with a voucher or gift card, so only the $34.88 on your card counts. The receipt total was $184.88.", shown.fetch(:message)
    assert_equal "Count all $184.88", shown.fetch(:count_all_label)
    assert_nil shown[:count_new_money_label]
    assert_equal [ 129.99, 54.89 ], shown.fetch(:count_all_splits).map { |split| split.fetch(:amount).to_f }
  end

  test "counting all of the receipt is her choice and the card then offers the new money back" do
    document = receipt_import
    HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ voucher_receipt ]).call
    draft = document.transaction_drafts.sole
    shown = HouseholdFinance::ReceiptTenders.presentation(draft)

    result = HouseholdFinance::TransactionDraftUpdater.new(draft, { amount: shown.fetch(:receipt_total), splits: shown.fetch(:count_all_splits) }).call

    assert result.success?, result.errors.to_sentence
    assert_equal 18_488, draft.reload.total_amount_cents
    assert_equal [ 12_999, 5_489 ], draft.transaction_draft_splits.order(:id).map(&:amount_cents)
    again = HouseholdFinance::ReceiptTenders.presentation(draft)
    assert_equal "all", again.fetch(:counting)
    assert_equal "Counting all $184.88, including the $150.00 paid with a voucher or gift card.", again.fetch(:message)
    assert_equal "Count only $34.88", again.fetch(:count_new_money_label)
    assert_equal [ 24.52, 10.36 ], again.fetch(:count_new_money_splits).map { |split| split.fetch(:amount).to_f }
  end

  test "the summary is read for a one-purchase receipt when the row does not say how it was paid" do
    document = receipt_import
    payload = voucher_receipt(evidence: "Home fan 129.99; Shelf kit 54.89; TOTAL $184.88", warnings: [])

    HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ payload ],
      summary: "Receipt dated 2026-06-23, total $184.88. Paid with a $150.00 voucher/gift card and $34.88 on debit card 7302.").call

    assert_equal 3_488, document.transaction_drafts.sole.total_amount_cents
  end

  test "payment lines that do not add up leave the receipt as read" do
    document = receipt_import
    payload = voucher_receipt(evidence: "TOTAL $184.88; Gift card $150.00; Debit card 7302 $30.00", warnings: [])

    HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ payload ]).call

    draft = document.transaction_drafts.sole
    assert_equal 18_488, draft.total_amount_cents
    assert_nil draft.draft_payload["receipt_payment"]
    assert_nil HouseholdFinance::ReceiptTenders.presentation(draft)
  end

  test "buying a gift card on a receipt still counts in full" do
    document = receipt_import
    payload = voucher_receipt(total_amount: 50, evidence: "Gift card purchase $50.00; TOTAL $50.00; Visa $50.00", warnings: [],
      splits: [ { amount: 50, category_name: "Gifts" } ])

    HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ payload ]).call

    assert_equal 5_000, document.transaction_drafts.sole.total_amount_cents
  end

  test "a statement row is never read for gift card payments" do
    payload = voucher_receipt(source_type: "statement")

    HouseholdFinance::DocumentTransactionDraftPersister.new(@document_import, [ payload ]).call

    assert_equal 18_488, @document_import.transaction_drafts.sole.total_amount_cents
  end

  test "all of it paid with a gift card keeps the amount and says none is new money" do
    document = receipt_import
    payload = voucher_receipt(total_amount: 40, evidence: "TOTAL $40.00; Gift card $40.00; Balance due $0.00", warnings: [],
      splits: [ { amount: 40, category_name: "Household" } ])

    HouseholdFinance::DocumentTransactionDraftPersister.new(document, [ payload ]).call

    draft = document.transaction_drafts.sole
    assert_equal 4_000, draft.total_amount_cents
    shown = HouseholdFinance::ReceiptTenders.presentation(draft)
    assert_equal "All $40.00 was paid with a gift card, so none of it is new money. Choose Not now to leave it out of your spending.", shown.fetch(:message)
    assert_nil shown[:count_all_label]
    assert_nil shown[:count_new_money_label]
  end
end
