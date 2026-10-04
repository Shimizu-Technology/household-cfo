require "test_helper"

class FinancialBaselinesTest < ActiveSupport::TestCase
  OPS = HouseholdFinance::Operations

  setup do
    @user = User.create!(clerk_id: "baseline-#{SecureRandom.hex(8)}", email: "baseline-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic baseline")
    @household.household_memberships.create!(user: @user, role: "owner")
    @category = @household.budget_categories.create!(name: "Synthetic reviewed category", stack_key: "discretionary", sort_order: 0)
  end

  test "three fully reviewed calendar months approve immutable exact versioned coverage" do
    sources = %w[06 07 08].map { |month| reviewed_source([ movement(-10_000, date: "2026-#{month}-07") ], first: "2026-#{month}-01", last: Date.iso8601("2026-#{month}-01").end_of_month.iso8601, tracked: @tracked) }
    input = request(sources, first: "2026-06-01", last: "2026-08-31")
    preview = preview(input)
    assert preview[:complete_eligible], preview[:deficiencies].inspect
    assert_equal 30_000, preview[:patterns][:gross_spending_cents]
    assert_equal 3, preview[:window_complete_calendar_month_count]
    version = approve(input, status: "complete")
    assert_equal "complete", version.coverage_status
    assert_equal 3, version.snapshot["source_revisions"].length
    assert_raises(ActiveRecord::ReadOnlyRecord) { version.update!(coverage_status: "partial") }
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { FinancialBaselineVersion.where(id: version.id).update_all(snapshot: {}) }
    end
  end

  test "partial September is not a complete month or three month evidence" do
    source = reviewed_source([ movement(-10_000, date: "2026-09-07") ], first: "2026-09-01", last: "2026-09-15")
    input = request([ source ], first: "2026-09-01", last: "2026-09-30")
    result = preview(input)
    refute result[:complete_eligible]
    assert_equal [ { start_on: "2026-09-16", end_on: "2026-09-30" } ], result[:account_coverage].sole[:missing_ranges]
    assert_equal 0, result[:supported_complete_calendar_month_count]
    assert_raises(ArgumentError) { approve(input, status: "complete") }
    assert_equal "partial", approve(input, status: "partial").coverage_status
  end

  test "more than one hundred rows contribute to merchant frequency and full window totals" do
    rows = [ movement(-5_000, date: "2026-07-01", merchant: "Early Ross") ] + 120.times.map { |index| movement(-100, row: index + 2, merchant: "Cafe") }
    source = reviewed_source(rows)
    result = preview(request([ source ]))
    assert_equal 17_000, result[:patterns][:gross_spending_cents]
    assert_equal 121, result[:patterns][:expense_count]
    assert_equal 120, result[:patterns][:merchants].find { |row| row[:merchant] == "Cafe" }[:frequency]
    assert_equal 5_000, result[:patterns][:merchants].find { |row| row[:merchant] == "Early Ross" }[:net_cents]
    presented = FinancialBaselines::Preview.presentation(result)
    assert_equal 50, presented[:sample_rows].length
    assert_equal 121, presented[:represented_row_count]
    assert presented[:aggregates_use_full_window]
  end

  test "manual Plaid and typed projections count canonical expenses once after explicit matching" do
    source = reviewed_source([ movement(-10_000) ])
    run_operation(OPS::SourceReview::ExpenseProject, version_id: source[:versions].first.id, expected_version_digest: source[:versions].first.digest, projection: { action: "create" }, reason: "Synthetic explicit spending projection")
    manual = actual(10_000, merchant: "Synthetic merchant")
    plaid = actual(10_000, merchant: "Synthetic merchant", type: "plaid")
    unique = actual(2_000, merchant: "Unique manual purchase", date: "2026-07-09")
    input = request([ source ]).merge(cash_coverage: "complete", actual_decisions: [
      decision(manual, disposition: "match", source_review_version_id: source[:versions].first.id),
      decision(plaid, disposition: "match", source_review_version_id: source[:versions].first.id), decision(unique, cash: true) ])
    result = preview(input)
    assert_equal 12_000, result[:patterns][:gross_spending_cents]
    assert_equal 2, result[:patterns][:expense_count]
    assert_equal 4, result[:actual_snapshots].length
  end

  test "unresolved date amount overlaps cannot be called complete but may be explicitly distinct" do
    source = reviewed_source([ movement(-10_000) ])
    manual = actual(10_000)
    input = request([ source ]).merge(actual_decisions: [ decision(manual, tracked_account_id: @tracked.id) ])
    result = preview(input)
    assert_equal 1, result[:possible_overlaps].length
    refute result[:complete_eligible]
    input[:actual_decisions] = [ decision(manual, tracked_account_id: @tracked.id, overlap_disposition: "distinct") ]
    assert preview(input)[:complete_eligible]
    assert_equal 20_000, preview(input)[:patterns][:gross_spending_cents]
  end

  test "merchant names never imply optional spending and annual context remains a participant assumption" do
    source = reviewed_source([ movement(-10_000, merchant: "General retailer pharmacy") ])
    input = request([ source ]).merge(category_eligibility: [ { budget_category_id: @category.id, eligible: false, recurrence: "annual", reason: "Necessary medicine and a reviewed annual purchase" } ])
    result = preview(input)
    assert_equal 0, result[:patterns][:eligible_net_spending_cents]
    assert_equal "annual", result[:patterns][:categories].sole[:recurrence]
    refute result[:patterns][:merchants].sole[:optional_spending_inferred]
    refute result[:patterns][:recurrence_inferred]
    refute result[:patterns][:savings_inferred]
  end

  test "same window refund nets purchase without becoming income or savings" do
    source = reviewed_source([ movement(-10_000), movement(2_500, row: 2, date: "2026-07-08", type: "refund") ])
    refund_link(source[:versions][0], source[:versions][1], 2_500)
    attest(source)
    result = preview(request([ source ]))
    assert_equal 7_500, result[:patterns][:net_spending_cents]
    assert_equal 7_500, result[:patterns][:same_window_net_spending_cents]
    assert_equal 0, result[:patterns][:income_cents]
    assert_equal 0, result[:patterns][:prior_window_refunds_cents]
    refute result[:patterns][:savings_inferred]
  end

  test "prior window refund remains a timing reversal with required dependency coverage" do
    purchase = reviewed_source([ movement(-10_000, date: "2026-06-07") ], first: "2026-06-01", last: "2026-06-30")
    refund = reviewed_source([ movement(2_500, date: "2026-07-08", type: "refund") ], tracked: @tracked)
    refund_link(purchase[:versions].first, refund[:versions].first, 2_500)
    attest(purchase)
    attest(refund)
    result = preview(request([ refund ]))
    assert_equal(-2_500, result[:patterns][:net_spending_cents])
    assert_equal 0, result[:patterns][:same_window_net_spending_cents]
    assert_equal 2_500, result[:patterns][:prior_window_refunds_cents]
    assert_equal 0, result[:patterns][:comparable_eligible_spending_cents]
    assert_equal [ purchase[:revision].id ], result[:dependency_revision_ids]
    assert_equal 2, result[:source_revisions].length
  end

  test "cash withdrawal and manually allocated purchase leave cash unknown not saved" do
    source = reviewed_source([ movement(-10_000, type: "cash_withdrawal") ])
    purchase = actual(4_000, date: "2026-07-08", merchant: "Cash purchase")
    input = request([ source ]).merge(cash_coverage: "complete", actual_decisions: [ decision(purchase, cash: true) ], cash_allocations: [ { source_review_version_id: source[:versions].first.id, transaction_id: purchase.id, amount_cents: 4_000, reason: "Participant allocated this withdrawal to this purchase" } ])
    result = preview(input)
    assert_equal 4_000, result[:patterns][:gross_spending_cents]
    assert_equal 6_000, result[:cash][:unallocated_withdrawal_cents]
    refute result[:cash][:cash_balance_known]
    refute result[:cash][:savings_inferred]
    input[:cash_allocations].first[:amount_cents] = 10_001
    assert_raises(ArgumentError) { preview(input) }
  end

  test "missing account and unreviewed rows remain qualified instead of full household coverage" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ]).merge(missing_accounts: [ "Another unprovided card" ])
    refute preview(input)[:complete_eligible]
    assert_includes preview(input)[:deficiencies], "missing_accounts_declared"
    assert_equal "partial", approve(input, status: "partial").coverage_status
    source[:versions].first.source_review_head.update!(approved_version: nil)
    refute preview(request([ source ]))[:complete_eligible]
  end

  test "manual baseline without statements is allowed and absent observations are unknown" do
    input = request([]).merge(tracked_account_ids: [], cash_coverage: "unknown", household_scope_attested: false)
    result = preview(input)
    refute result[:observed_spending_known]
    assert_equal 0, result[:supported_complete_calendar_month_count]
    assert_equal "manual", approve(input, status: "manual").coverage_status
    assert_raises(ArgumentError) { approve(input, status: "complete") }
  end

  test "approved revisions retain previous checkpoint source and category history" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ])
    first = approve(input, status: "complete")
    old_snapshot = first.snapshot.deep_dup
    @category.update!(name: "Corrected reviewed context")
    second = revise(input, first)
    assert_equal first.id, second.supersedes_id
    assert_equal 2, second.version_number
    assert_equal old_snapshot, first.reload.snapshot
    assert_equal "Synthetic reviewed category", first.snapshot["category_eligibility"].sole["name"]
    assert_equal "Corrected reviewed context", second.snapshot["category_eligibility"].sole["name"]
  end

  test "source changes actual changes and category changes invalidate prepared approval" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ])
    operation = OPS::Baseline::Approve.new(@household, user: @user)
    prepared = operation.prepare(approval_input(input, "complete"))
    @category.update!(name: "Another context")
    assert_raises(OPS::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_empty FinancialBaselineVersion.where(household: @household)
    manual = actual(500, date: "2026-07-09")
    input[:actual_decisions] = [ decision(manual, cash: true) ]
    input[:cash_coverage] = "complete"
    prepared = operation.prepare(approval_input(input, "complete"))
    manual.update!(merchant: "Corrected merchant")
    assert_raises(OPS::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
  end

  test "participant permission is checked before previews again at approval and at replay" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ])
    operation = OPS::Baseline::Approve.new(@household, user: @user)
    prepared = operation.prepare(approval_input(input, "complete"))
    @user.update!(role: "coach")
    assert_raises(ArgumentError) { preview(input) }
    assert_raises(ArgumentError) { operation.execute!(prepared, source: "manual") }
    @user.update!(role: "participant")
    version = approve(input, status: "complete")
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    assert_raises(ArgumentError) { operation.authorize_replay!(version) }
  end

  test "asset liability signs preserve consumption while transfers and debt payments stay movements" do
    asset = reviewed_source([ movement(-10_000, type: "debt_payment") ])
    liability = reviewed_source([ movement(10_000, type: "debt_payment"), movement(-2_000, row: 2, type: "purchase", date: "2026-07-08") ], basis: "liability")
    result = preview(request([ asset, liability ]))
    assert_equal 2_000, result[:patterns][:gross_spending_cents]
    assert_equal 10_000, result[:patterns][:debt_payments][:outflow_cents]
    assert_equal 10_000, result[:patterns][:debt_payments][:inflow_cents]
    assert_equal %w[asset liability], result[:account_coverage].pluck(:account_basis).sort
  end

  test "pending source corrections do not change the approved baseline dataset" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ])
    baseline = approve(input, status: "complete")
    version = source[:versions].first
    head = version.source_review_head.reload
    run_operation(OPS::SourceReview::DraftStage, event_id: version.financial_source_event.id, base_version_id: version.id, base_lock_version: head.lock_version,
      reason: "Pending correction only", projection: { action: "none" }, facts: version.reviewed_facts.merge(signed_amount_cents: -9_000, purchase_amount_cents: 9_000))
    assert_equal baseline.digest, preview(input)[:digest]
    result = FinancialBaselines::Reader.new(@household, user: @user).current
    refute result[:needs_revision]
    assert_equal baseline.id, result[:approved_version].id
  end

  test "unprovided known canonical account and contradictory adjacent balances cannot be complete" do
    first = reviewed_source([ movement(-10_000) ])
    second = reviewed_source([ movement(-2_000, date: "2026-07-08") ])
    result = preview(request([ first ]))
    refute result[:complete_eligible]
    assert_includes result[:deficiencies], "known_source_account_omitted:#{second[:identity].source_tracked_account_id}"
    next_month = reviewed_source([ movement(-1_000, date: "2026-08-07") ], tracked: first[:identity].source_tracked_account, first: "2026-08-01", last: "2026-08-31")
    account_head = next_month[:identity].source_account_review_head.reload
    facts = next_month[:identity].statement_facts.merge("opening_balance_cents" => 299_000, "closing_balance_cents" => 298_000)
    next_month[:identity] = run_operation(OPS::SourceReview::AccountLink, source_account_id: account_head.financial_source_account_id, tracked_account_id: account_head.approved_version.source_tracked_account_id,
      base_version_id: account_head.approved_version_id, base_lock_version: account_head.lock_version, statement_facts: facts, reason: "Synthetic contradictory carry balance")
    input = request([ first, second, next_month ], last: "2026-08-31")
    refute preview(input)[:complete_eligible]
    assert_includes preview(input)[:deficiencies], "account_balance_discontinuity:#{first[:identity].source_tracked_account_id}"
  end

  test "private historical reader rejects another participant and preserves unavailable current inputs" do
    source = reviewed_source([ movement(-10_000) ])
    input = request([ source ])
    baseline = approve(input, status: "complete")
    reader = FinancialBaselines::Reader.new(@household, user: @user)
    assert_equal baseline.id, reader.find(baseline.id).id
    partner = User.create!(clerk_id: "partner-#{SecureRandom.hex(8)}", email: "partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household.household_memberships.create!(user: partner, role: "partner")
    assert_raises(ActiveRecord::RecordNotFound) { FinancialBaselines::Reader.new(@household, user: partner).find(baseline.id) }
    assert_nil FinancialBaselines::Reader.new(@household, user: partner).current[:approved_version]
    @category.update!(name: "New category context")
    assert reader.current[:needs_revision]
    assert_equal "Synthetic reviewed category", reader.find(baseline.id).snapshot["category_eligibility"].sole["name"]
  end

  test "duplicate match cycles and unresolved Plaid classifications are rejected or incomplete" do
    first = actual(1_000, type: "plaid")
    second = actual(1_000, type: "manual_ui")
    input = request([]).merge(cash_coverage: "complete", tracked_account_ids: [])
    assert_includes preview(input)[:deficiencies], "actual_classification_unreviewed:#{first.id}"
    input[:actual_decisions] = [ decision(first, disposition: "match", matched_transaction_id: second.id), decision(second, disposition: "match", matched_transaction_id: first.id) ]
    assert_raises(ArgumentError) { preview(input) }
  end

  test "future malformed and cross household baseline requests fail before exposing values" do
    input = request([])
    assert_raises(ArgumentError) { preview(input.merge(window_end_on: (Date.current + 1).iso8601)) }
    assert_raises(ArgumentError) { preview(input.merge(window_start_on: "July 1, 2026")) }
    foreign = Household.create!(created_by_user: @user, name: "Other synthetic scope")
    @household.household_memberships.find_by!(user: @user).update!(role: "partner")
    foreign.household_memberships.create!(user: @user, role: "owner")
    source = reviewed_source([ movement(-10_000) ])
    assert_raises(ActiveRecord::RecordNotFound) { FinancialBaselines::Preview.new(foreign, user: @user).call(request([ source ])) }
  end

  test "active actual exclusions are explicit limitations and cannot certify complete spending" do
    source = reviewed_source([ movement(-10_000) ])
    transaction = actual(500, date: "2026-07-08")
    input = request([ source ]).merge(actual_decisions: [ decision(transaction, disposition: "exclude") ])
    result = preview(input)
    assert_equal 10_000, result[:patterns][:gross_spending_cents]
    refute result[:complete_eligible]
    assert_includes result[:deficiencies], "active_actual_excluded:#{transaction.id}"
  end

  test "duplicate match evidence pins actual facts even when omitted from canonical totals" do
    source = reviewed_source([ movement(-10_000) ])
    duplicate = actual(10_000)
    input = request([ source ]).merge(actual_decisions: [ decision(duplicate, disposition: "match", source_review_version_id: source[:versions].first.id) ])
    operation = OPS::Baseline::Approve.new(@household, user: @user)
    prepared = operation.prepare(approval_input(input, "complete"))
    duplicate.update!(merchant: "Edited duplicate evidence")
    assert_raises(OPS::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_empty FinancialBaselineVersion.where(household: @household)
  end

  test "database cannot attribute approval to another household participant" do
    source = reviewed_source([ movement(-10_000) ])
    version = approve(request([ source ]), status: "complete")
    partner = User.create!(clerk_id: "other-actor-#{SecureRandom.hex(8)}", email: "other-actor-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household.household_memberships.create!(user: partner, role: "partner")
    attrs = version.attributes.except("id").merge("version_number" => 2, "supersedes_id" => version.id, "approved_by_user_id" => partner.id)
    assert_raises(ActiveRecord::RecordInvalid) { FinancialBaselineVersion.create!(attrs) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { FinancialBaselineVersion.insert!(attrs) }
    end
    assert_equal 1, FinancialBaselineVersion.where(household: @household).count
  end

  private

  def run_operation(klass, input)
    operation = klass.new(@household, user: @user)
    prepared = operation.prepare(input)
    ApplicationRecord.transaction do
      result = operation.execute!(prepared, source: "manual")
      operation.send(:verify_after!, prepared.predicted_after_snapshot, operation.after_snapshot(result, prepared))
      result
    end
  end

  def movement(amount, row: 1, date: "2026-07-07", merchant: "Synthetic merchant", type: "purchase")
    { account_key: "synthetic", row_kind: "posted", event_type: type, signed_amount_cents: amount, posted_on: date, merchant: merchant, locator: { page: 1, row: row } }
  end

  def reviewed_source(rows, first: "2026-07-01", last: "2026-07-31", basis: "asset", tracked: nil)
    import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    net = rows.sum { |row| row[:signed_amount_cents] }
    prior = tracked && SourceAccountIdentityVersion.where(household: @household, source_tracked_account: tracked).where("statement_facts ->> 'period_end_on' < ?", first).order(:id).last
    opening = prior&.statement_facts&.dig("closing_balance_cents") || 300_000
    normalized = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic", account_basis: basis, period_start_on: first, period_end_on: last, opening_balance_cents: opening,
        closing_balance_cents: opening + (basis == "liability" ? -net : net), printed_debit_cents: rows.sum { |row| [ -row[:signed_amount_cents], 0 ].max }, printed_credit_cents: rows.sum { |row| [ row[:signed_amount_cents], 0 ].max }, printed_row_count: rows.length } ], events: rows, reported_row_count: rows.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: normalized).call
    import.update!(metadata: { "source_accounting_revision_id" => result[:revision].id })
    account = result[:revision].financial_source_accounts.sole
    identity = run_operation(OPS::SourceReview::AccountLink, source_account_id: account.id, tracked_account_id: tracked&.id, account_basis: basis, label: "Synthetic #{basis}", base_version_id: nil, base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Participant reviewed synthetic account")
    @tracked = identity.source_tracked_account
    versions = result[:events].each_with_index.map do |event, index|
      row = rows[index]
      purchase = row[:signed_amount_cents].negative? && row[:event_type].in?(%w[purchase fee interest]) ? row[:signed_amount_cents].abs : nil
      draft = run_operation(OPS::SourceReview::DraftStage, event_id: event.id, base_version_id: nil, base_lock_version: 0, reason: "Participant reviewed synthetic fact", projection: { action: "none" },
        facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: row[:event_type], signed_amount_cents: row[:signed_amount_cents], purchase_amount_cents: purchase,
          posted_on: row[:posted_on], merchant: row[:merchant], budget_category_id: @category.id, overlap_disposition: "distinct" })
      run_operation(OPS::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
    end
    result = result.merge(identity: identity, versions: versions, import: import)
    attest(result)
    result
  end

  def attest(source)
    identity = source[:identity]
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, source[:revision]).call
    run_operation(OPS::SourceReview::RevisionApprove, revision_id: source[:revision].id, expected_digest: state[:content_digest], requested_status: "complete", reason: "Participant explicitly approved synthetic complete coverage",
      coverage_attestation: { all_document_rows_accounted: true, accounts: [ { source_account_id: identity.source_account_review_head.financial_source_account_id, identity_version_id: identity.id,
        period_start_on: identity.statement_facts["period_start_on"], period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: true } ] })
  end

  def request(sources, first: "2026-07-01", last: "2026-07-31")
    { window_start_on: first, window_end_on: last, revision_ids: sources.map { |source| source[:revision].id }, tracked_account_ids: sources.map { |source| source[:identity].source_tracked_account_id }.uniq,
      household_scope_attested: true, cash_coverage: "not_used", category_eligibility: [ { budget_category_id: @category.id, eligible: true, recurrence: "unknown", reason: "Participant chose comfortable category eligibility" } ] }
  end

  def preview(input) = FinancialBaselines::Preview.new(@household, user: @user).call(input)

  def approval_input(input, status, prior = nil)
    head = FinancialBaselineHead.find_by(household: @household, participant_user: @user)
    { request: input, coverage_status: status, base_version_id: prior&.id, base_lock_version: head&.lock_version || 0, expected_preview_digest: preview(input)[:digest], reason: "Participant explicitly approved this baseline" }
  end

  def approve(input, status:) = run_operation(OPS::Baseline::Approve, approval_input(input, status))
  def revise(input, prior) = run_operation(OPS::Baseline::Revise, approval_input(input, prior.coverage_status, prior))

  def actual(amount, merchant: "Synthetic manual", date: "2026-07-07", type: "manual_ui")
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.iso8601(date))
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: amount, source_type: type, status: "confirmed")
    transaction.transaction_splits.create!(budget_category: @category, amount_cents: amount)
    transaction
  end

  def decision(transaction, **options)
    { transaction_id: transaction.id, event_type: "purchase", disposition: "include", reason: "Participant reviewed actual identity and context" }.merge(options)
  end

  def refund_link(purchase, refund, amount)
    run_operation(OPS::SourceReview::EconomicLink, base_version_id: nil, base_lock_version: 0, kind: "refund", reason: "Participant reviewed this exact refund allocation",
      members: [ { source_review_version_id: purchase.id, role: "original_purchase", allocation_cents: amount }, { source_review_version_id: refund.id, role: "refund", allocation_cents: amount } ])
  end
end
