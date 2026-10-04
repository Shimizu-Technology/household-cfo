require "test_helper"

class FinancialDocumentsSourceAccountingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "source-accounting-#{SecureRandom.hex(8)}", email: "source-accounting-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic source accounting")
    @import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "processing", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/source.pdf")
    @attempt = @import.attempts.create!(provider: "synthetic", model: "synthetic", status: "processing", prompt_version: "synthetic", schema_version: "synthetic", started_at: Time.current)
  end

  test "asset and liability account basis reconcile with signed economic flows without approving facts" do
    %w[asset liability].each do |basis|
      rows = [ event(-1_000), event(500, type: "refund", row: 2) ]
      closing = basis == "asset" ? 9_500 : 10_500
      accounting = normalized(rows, account: account(account_basis: basis, closing_balance_cents: closing, printed_debit_cents: 1_000, printed_credit_cents: 500))
      report = FinancialDocuments::SourceReconciliation.new(accounting).call

      assert_equal 0, report[:accounts].first[:balance_residual_cents]
      assert report[:accounts].first[:arithmetic_balanced]
      assert_equal "unreviewed", report[:status]
      refute report[:participant_approved]
    end
  end

  test "retains credits transfers debt payments and missing-date rows while staging only real expense projections" do
    rows = [ event(-1_000), event(500, type: "refund", row: 2), event(-2_000, type: "transfer", row: 3), event(-3_000, type: "debt_payment", row: 4), event(-400, row: 5, posted_on: "not-a-date") ]
    result = persist(normalized(rows))

    assert_equal 5, result[:events].length
    assert_equal [ "purchase", "refund", "transfer", "debt_payment", "purchase" ], result[:events].map(&:event_type)
    assert_equal "unresolved", result[:events].last.row_kind
    assert_equal(-400, result[:events].last.signed_amount_cents)
    assert_equal 1, result[:transaction_drafts].length
    assert_equal 1_000, result[:transaction_drafts].first[:total_amount_cents]
    assert_equal 0, @household.household_transactions.count
    assert_equal 1, result[:reconciliation][:accounts].first[:unresolved_rows]
  end

  test "returned-unpaid principal and period fee summaries are informational not extra spending" do
    rows = [ event(-111_000, merchant: "Returned unpaid principal"), event(-1_500, type: "fee", row: 2, merchant: "Total fees for the statement period"), event(-1_500, type: "fee", row: 3, merchant: "Posted service fee", posted_on: "2026-07-08") ]
    result = persist(normalized(rows))

    assert_equal %w[informational informational posted], result[:events].map(&:row_kind)
    assert_nil result[:events].first.signed_amount_cents
    assert_equal 1, result[:transaction_drafts].length
    assert_equal "2026-07-08", result[:transaction_drafts].first[:occurred_on]
    assert_equal 1_500, result[:reconciliation][:accounts].first[:debit_cents]
  end

  test "an embedded overdraft cause amount cannot override a disagreeing printed amount column" do
    result = persist(normalized([ event(-98_765, type: "fee", amount_column_cents: 3_500, merchant: "Overdraft fee caused by a larger unpaid item") ]))

    assert_equal "unresolved", result[:events].first.row_kind
    assert_includes result[:events].first.limitations, "amount_column_disagrees"
    assert_empty result[:transaction_drafts]
  end

  test "wallet split funding uses the wallet leg for balance and one full economic purchase for expense" do
    parts = [ { account_key: "test-account", amount_cents: 3_000 }, { account_key: "test-bank", amount_cents: 97_000 } ]
    row = event(-3_000, purchase_total_cents: 100_000, funding_components: parts)
    result = persist(normalized([ row ]))

    assert_equal(-3_000, result[:events].first.signed_amount_cents)
    assert_equal 100_000, result[:transaction_drafts].first[:total_amount_cents]
    incorrect = normalized([ row.merge(signed_amount_cents: -97_000, amount_column_cents: 97_000) ])
    assert_equal "unresolved", incorrect[:events].first[:row_kind]
    assert_includes incorrect[:events].first[:limitations], "split_funding_does_not_reconcile"
  end

  test "identical purchases on distinct rows are retained but duplicate exact locators remain unresolved" do
    result = persist(normalized([ event(-1_000), event(-1_000, row: 2) ]))
    assert_equal 2, result[:events].length
    assert_equal 2, result[:transaction_drafts].length
    assert_equal 2, result[:events].map(&:row_identity).uniq.length

    duplicate = normalized([ event(-1_000), event(-1_000) ])
    assert duplicate[:events].all? { |row| row[:row_kind] == "unresolved" && row[:limitations].include?("duplicate_source_locator") }
  end

  test "cross-year posted and authorization dates stay distinct and printed period is not inferred from rows" do
    header = account(period_start_on: "2025-12-20", period_end_on: "2026-01-19")
    rows = [ event(-1_000, posted_on: "2026-01-02", authorized_on: "2025-12-31") ]
    result = persist(normalized(rows, account: header))

    assert_equal Date.new(2026, 1, 2), result[:events].first.posted_on
    assert_equal Date.new(2025, 12, 31), result[:events].first.authorized_on
    assert_equal Date.new(2025, 12, 20), result[:revision].financial_source_accounts.first.period_start_on
    wrong = normalized([ rows.first.merge(posted_on: "2025-01-02") ], account: header)
    assert_includes wrong[:events].first[:limitations], "posted_date_outside_statement_period"
  end

  test "unknown coverage totals and census mismatches are explicit even if arithmetic balances" do
    accounting = normalized([ event(-1_000) ], account: account(closing_balance_cents: 9_000, printed_debit_cents: 1_000, printed_credit_cents: 0), reported_row_count: 2)
    accounting[:coverage][:processed_pages] = [ 1 ]
    accounting[:coverage][:expected_page_count] = 2
    report = FinancialDocuments::SourceReconciliation.new(accounting).call

    assert report[:accounts].first[:arithmetic_balanced]
    assert_equal false, report[:row_census][:matches_reported]
    assert_equal false, report[:page_coverage][:all_processed]
    assert_includes report[:limitations], "reported_row_census_mismatch"
    assert_includes report[:limitations], "page_coverage_incomplete"
    refute report[:participant_approved]
    unknown = FinancialDocuments::SourceReconciliation.new(normalized([ event(-1_000) ], account: { account_key: "test-account", account_basis: "unknown" })).call
    assert_nil unknown[:accounts].first[:balance_residual_cents]
    refute unknown[:accounts].first[:arithmetic_balanced]
    assert_includes unknown[:accounts].first[:limitations], "opening_or_closing_balance_unknown"
  end

  test "facts cannot mutate through models or SQL while raw evidence can be erased" do
    result = persist(normalized([ event(-1_000) ]))
    row = result[:events].first
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(signed_amount_cents: -2_000) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { FinancialSourceEvent.where(id: row.id).update_all(signed_amount_cents: -2_000) }
    end
    row.financial_source_evidence.destroy!
    assert_equal(-1_000, row.reload.signed_amount_cents)
    assert_nil row.reload.financial_source_evidence
  end

  test "import deletion nullifies lineage references without destroying source facts" do
    result = persist(normalized([ event(-1_000) ]))
    @import.destroy!

    assert_nil result[:revision].reload.financial_document_import_id
    assert_nil result[:revision].financial_document_import_attempt_id
    assert_equal 1, FinancialSourceEvent.where(household: @household).count
  end

  test "approved positive spending keeps source linkage and re-extraction preserves old source-linked drafts" do
    category = @household.budget_categories.create!(name: "Synthetic groceries", stack_key: "non_discretionary", sort_order: 0)
    result = persist(normalized([ event(-1_000, category_name: category.name) ]))
    HouseholdFinance::DocumentTransactionDraftPersister.new(@import, result[:transaction_drafts]).call
    draft = @import.transaction_drafts.sole
    confirmation = HouseholdFinance::TransactionDraftConfirmer.new(draft, { budget_category_id: category.id }).call

    assert confirmation.success?, confirmation.errors.inspect
    assert_equal result[:events].first.id, confirmation.transaction.financial_source_event_id
    assert_equal 1_000, confirmation.transaction.total_amount_cents
    assert_equal(-1_000, result[:events].first.reload.signed_amount_cents)
    second = persist(normalized([ event(-500, row: 2) ]), new_attempt: true)
    HouseholdFinance::DocumentTransactionDraftPersister.new(@import, second[:transaction_drafts]).call
    old_pending = @import.transaction_drafts.pending.sole
    third = persist(normalized([ event(-300, row: 3) ]), new_attempt: true)
    HouseholdFinance::DocumentTransactionDraftPersister.new(@import, third[:transaction_drafts]).call
    assert_equal "ignored", old_pending.reload.status
    assert_equal 3, FinancialExtractionRevision.where(household: @household).count
    assert_equal 3, FinancialSourceEvent.where(household: @household).count
    assert_equal 1_000, confirmation.transaction.reload.total_amount_cents
    assert_equal confirmation.transaction.id, draft.reload.confirmed_transaction_id
    assert_includes %w[confirmed corrected], draft.status
  end

  test "presenter excludes raw evidence by default and rejects records from another revision" do
    result = persist(normalized([ event(-1_000) ]))
    presenter = FinancialDocuments::SourceAccountingPresenter.new(result[:revision])
    refute presenter.event(result[:events].first).key?(:evidence)
    refute presenter.summary[:accounts].first.key?(:evidence)
    assert_equal "source_accounting_v1", presenter.summary[:contract_version]
    assert_match(/\A[0-9a-f]{64}\z/, presenter.summary[:source_document_identity])
    explicit = FinancialDocuments::SourceAccountingPresenter.new(result[:revision], include_evidence: true)
    assert_equal "Synthetic merchant", explicit.event(result[:events].first)[:evidence]["merchant"]
    second = persist(normalized([ event(-500) ]), new_attempt: true)
    assert_raises(ArgumentError) { presenter.event(second[:events].first) }
  end

  test "malformed rows are retained unresolved and an oversized extraction fails without truncation" do
    accounting = normalized([ nil, "not a row", event(-500) ])
    assert_equal 3, accounting[:events].length
    assert_equal %w[unresolved unresolved posted], accounting[:events].map { |row| row[:row_kind] }
    assert_equal '"not a row"', accounting[:events][1][:evidence][:malformed_extraction_row]
    assert_raises(ArgumentError) { normalized(Array.new(FinancialDocuments::AccountingContract::MAX_EVENTS + 1) { event(-100) }) }
  end

  test "schema dump preserves database immutability guards on a fresh schema load" do
    stream = StringIO.new
    ActiveRecord::SchemaDumper.dump(ApplicationRecord.connection_pool, stream)
    assert_includes stream.string, "CREATE OR REPLACE FUNCTION public.source_accounting_facts_immutable()"
    %w[financial_extraction_revisions financial_source_accounts financial_source_events].each do |table|
      assert_includes stream.string, "CREATE TRIGGER #{table}_immutable"
    end
  end

  test "database prevents evidence and source projection links crossing households" do
    result = persist(normalized([ event(-1_000) ]))
    other = Household.create!(created_by_user: @user, name: "Other synthetic household")
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { result[:events].first.financial_source_evidence.update_columns(household_id: other.id) }
    end
    HouseholdFinance::DocumentTransactionDraftPersister.new(@import, result[:transaction_drafts]).call
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { @import.transaction_drafts.sole.update_columns(household_id: other.id) }
    end
  end

  test "typed source review stays in pending counts after legacy expense application" do
    @import.update!(status: "applied", metadata: { source_accounting_review_pending: true })
    assert_includes FinancialDocumentImport.pending_review, @import
    @import.update!(status: "failed")
    refute_includes FinancialDocumentImport.pending_review, @import
    @import.update!(status: "source_deleted", source_deleted_at: Time.current)
    refute_includes FinancialDocumentImport.pending_review, @import
  end

  private

  def account(**overrides)
    { account_key: "test-account", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31", opening_balance_cents: 10_000, closing_balance_cents: nil, printed_debit_cents: nil, printed_credit_cents: nil }.merge(overrides)
  end

  def event(amount, type: "purchase", row: 1, **overrides)
    { account_key: "test-account", row_kind: "posted", event_type: type, signed_amount_cents: amount, amount_column_cents: amount.abs, posted_on: "2026-07-07", locator: { page: 1, row: row }, merchant: "Synthetic merchant" }.merge(overrides)
  end

  def normalized(rows, account: self.account, reported_row_count: nil)
    FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [ account ], events: rows, reported_row_count: reported_row_count }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
  end

  def persist(accounting, new_attempt: false)
    if new_attempt
      @attempt = @import.attempts.create!(provider: "synthetic", model: "synthetic", status: "processing", prompt_version: "synthetic", schema_version: "synthetic", started_at: Time.current)
    end
    FinancialDocuments::SourceAccountingPersister.new(@import, attempt: @attempt, accounting: accounting).call
  end
end
