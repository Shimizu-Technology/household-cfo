require "test_helper"

class FinancialDocumentsSourceFragmentReviewTest < ActiveSupport::TestCase
  OPS = HouseholdFinance::Operations::SourceReview

  setup do
    @user = User.create!(clerk_id: "fragment-#{SecureRandom.hex(8)}", email: "fragment-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Fictional fragment review")
    @category = @household.budget_categories.create!(name: "Fictional purchases", stack_key: "non_discretionary", sort_order: 0)
    @household.household_memberships.create!(user: @user, role: "owner")
  end

  test "125 physical rows reconcile once after all three fragments are explicitly linked to the same card and full period" do
    travel_to Time.zone.local(2027, 2, 1) do
      rows = Array.new(120) { |i| [ -(5 + i % 7) * 100, "purchase" ] } + [ [ -3321, "purchase" ], [ 1300, "refund" ], [ 25000, "debt_payment" ], [ -100, "fee" ], [ -1234, "interest" ] ]
      source = source(rows, sizes: [ 49, 60, 16 ], first: "2026-12-15", last: "2027-01-14")
      before = state(source)
      assert_equal 3, before[:reconciliation][:accounts].length
      assert_includes before[:deficiencies], "unreviewed_source_accounts"
      identities = review_accounts(source)
      approve_rows(source, identities)
      purchase = SourceReviewVersion.where(household: @household, signed_amount_cents: -3321).sole
      refund = SourceReviewVersion.where(household: @household, event_type: "refund").sole
      run_operation(OPS::EconomicLink, base_version_id: nil, base_lock_version: 0, kind: "refund", reason: "Participant checked the fictional refund against this purchase",
        members: [ { source_review_version_id: purchase.id, role: "original_purchase", allocation_cents: 1300 }, { source_review_version_id: refund.id, role: "refund", allocation_cents: 1300 } ])
      report = state(source)
      assert_equal 1, report[:reconciliation][:accounts].length
      account = report[:reconciliation][:accounts].sole
      assert_empty report[:deficiencies]
      assert_equal [ 125, 125 ], account.values_at(:represented_rows, :posted_rows)
      assert_equal [ 100355, 26300, 50000, 124055 ], account.values_at(:debit_cents, :credit_cents, :opening_balance_cents, :closing_balance_cents)
      assert_equal source[:accounts].map(&:id), account[:source_account_ids]
      assert_equal identities.map(&:id), account[:account_identity_version_ids]
      assert account[:arithmetic_balanced]
      approval = run_operation(OPS::RevisionApprove, coverage_input(source, identities))
      assert_equal "complete", approval.coverage_status
      assert_empty approval.deficiencies
      assert_equal 125, source[:revision].financial_source_events.count
      assert_equal 3, source[:revision].financial_source_accounts.count
      assert_empty @household.household_transactions
      assert_baseline_complete(source, identities.first, first: "2026-12-15", last: "2027-01-14")
    end
  end

  test "identical purchases remain distinct and repeated full headers are never summed" do
    source = source(Array.new(6) { [ -100, "purchase" ] }, sizes: [ 3, 2, 1 ])
    identities = review_accounts(source)
    approve_rows(source, identities)
    assert_equal 1, state(source)[:reconciliation][:accounts].length
    account = state(source)[:reconciliation][:accounts].sole
    assert_equal 600, account[:debit_cents]
    assert_equal 600, account[:printed_debit_cents]
    assert_equal 6, account[:printed_row_count]
    assert_equal 6, account[:represented_rows]
    assert_equal 6, SourceReviewVersion.where(household: @household).count
    assert_equal "complete", run_operation(OPS::RevisionApprove, coverage_input(source, identities)).coverage_status
  end

  test "unreviewed and unknown-header fragments do not merge or gain complete coverage" do
    source = small_source
    identities = review_accounts(source, overrides: { 1 => { "opening_balance_cents" => nil } })
    approve_rows(source, identities)
    assert_equal 2, state(source)[:reconciliation][:accounts].length
    assert_includes state(source)[:deficiencies], "account_reconciliation_incomplete"
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    other = small_source
    one = review_account(other[:accounts].first, other[:facts])
    assert_equal 3, state(other)[:reconciliation][:accounts].length
    assert_includes state(other)[:deficiencies], "unreviewed_source_accounts"
    assert_equal 1, state(other)[:account_version_ids].length
    assert_equal one.id, state(other)[:account_version_ids].sole
  end

  test "unknown statement period is not inferred from another confirmed fragment" do
    source = small_source
    identities = review_accounts(source, overrides: { 1 => { "period_start_on" => nil } })
    approve_rows(source, identities)
    assert_equal 2, state(source)[:reconciliation][:accounts].length
    assert_includes state(source)[:deficiencies], "account_reconciliation_incomplete"
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
  end

  test "different recognized accounts and different confirmed periods remain separate" do
    source = small_source
    identities = review_accounts(source, separate: [ 1 ])
    approve_rows(source, identities)
    assert_equal 2, state(source)[:reconciliation][:accounts].length
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    other = small_source
    identities = review_accounts(other, overrides: { 1 => { "period_start_on" => "2026-06-01" } })
    approve_rows(other, identities)
    assert_equal 2, state(other)[:reconciliation][:accounts].length
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(other, identities)) }
  end

  test "conflicting full headers and census fail closed even when merged movements balance" do
    %w[opening_balance_cents closing_balance_cents printed_debit_cents printed_credit_cents printed_row_count].each do |field|
      source = small_source
      identities = review_accounts(source, overrides: { 1 => { field => source[:facts][field] + 1 } })
      approve_rows(source, identities)
      report = state(source)
      assert_includes report[:reconciliation][:accounts].sole[:limitations], "conflicting_header_#{field}"
      refute report[:reconciliation][:accounts].sole[:arithmetic_balanced]
      assert_includes report[:deficiencies], "account_reconciliation_incomplete"
      assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    end
  end

  test "conflicting row count bases and partially unknown census never certify a grouped statement" do
    [ { "printed_row_count_basis" => "all" }, { "printed_row_count" => nil } ].each do |change|
      source = small_source
      identities = review_accounts(source, overrides: { 1 => change })
      approve_rows(source, identities)
      report = state(source)
      refute report[:reconciliation][:accounts].sole[:arithmetic_balanced]
      assert_includes report[:deficiencies], "account_reconciliation_incomplete"
      assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    end
  end

  test "matching account and period in another import never balance this revision" do
    first = small_source
    first_ids = review_accounts(first)
    approve_rows(first, first_ids)
    other = source([ [ -100, "purchase" ] ], sizes: [ 1 ])
    other_ids = review_accounts(other, tracked: first_ids.first.source_tracked_account, overrides: { 0 => first[:facts] })
    approve_rows(other, other_ids)
    assert_equal 6, state(first)[:reconciliation][:accounts].sole[:represented_rows]
    assert_equal 1, state(other)[:reconciliation][:accounts].sole[:represented_rows]
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(other, other_ids)) }
  end

  test "foreign household canonical account cannot be used to reunite fragments" do
    source = small_source
    foreign = Household.create!(created_by_user: @user, name: "Other fictional household")
    tracked = SourceTrackedAccount.create!(household: foreign, label: "Foreign fictional card", account_basis: "liability", approved_by_user: @user)
    assert_raises(ActiveRecord::RecordNotFound) { review_account(source[:accounts].first, source[:facts], tracked: tracked) }
    assert_empty state(source)[:account_version_ids]
  end

  test "source approval keeps exact digest fences and coverage becomes stale after a fragment correction" do
    source = small_source
    identities = review_accounts(source)
    approve_rows(source, identities)
    input = coverage_input(source, identities)
    operation = OPS::RevisionApprove.new(@household, user: @user)
    prepared = operation.prepare(input)
    prior = identities[1]
    changed = review_account(source[:accounts][1], source[:facts].merge("printed_debit_cents" => 601), tracked: prior.source_tracked_account, prior: prior)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_includes state(source)[:deficiencies], "account_identity_changed"
    assert_empty SourceRevisionApproval.where(household: @household)
    identities[1] = review_account(source[:accounts][1], source[:facts], tracked: prior.source_tracked_account, prior: changed)
    approve_rows(source, identities, only_account_id: source[:accounts][1].id)
    approval = run_operation(OPS::RevisionApprove, coverage_input(source, identities))
    assert_equal "complete", approval.coverage_status
    review_account(source[:accounts][2], source[:facts], tracked: identities.last.source_tracked_account, prior: identities.last)
    current = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ source[:revision].id ])[:revisions].sole
    refute current[:participant_approved]
    assert_equal "stale", current[:coverage_status]
    assert_empty @household.household_transactions
  end

  test "previous per-fragment complete approval becomes stale and cannot certify a baseline until true full headers are reviewed" do
    source = source([ [ -100, "purchase" ], [ -100, "purchase" ] ], sizes: [ 1, 1 ])
    partial_headers = source[:facts].merge("closing_balance_cents" => 50100, "printed_debit_cents" => 100, "printed_row_count" => 1)
    identities = review_accounts(source, overrides: { 0 => partial_headers, 1 => partial_headers })
    approve_rows(source, identities)
    prior = with_legacy_reconciliation(source, identities) do
      approval = run_operation(OPS::RevisionApprove, coverage_input(source, identities))
      assert_baseline_complete(source, identities.first, first: "2026-07-01", last: "2026-07-31", expected_rows: 2)
      approval
    end
    original_bytes = prior.attributes
    report = state(source)
    assert_includes report[:deficiencies], "account_reconciliation_incomplete"
    refute_equal prior.digest, report[:content_digest]
    reader = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ source[:revision].id ])[:revisions].sole
    refute reader[:participant_approved]
    assert_equal "stale", reader[:coverage_status]
    input = baseline_request(source, identities.first, first: "2026-07-01", last: "2026-07-31")
    preview = FinancialBaselines::Preview.new(@household, user: @user).call(input)
    refute preview[:complete_eligible]
    assert_includes preview[:deficiencies], "source_coverage_not_complete:#{source[:revision].id}"
    baseline = FinancialBaselines::Reader.new(@household, user: @user).current
    assert baseline[:needs_revision]
    assert_includes baseline[:current_deficiencies], "source_coverage_not_complete:#{source[:revision].id}"
    assert_raises(ArgumentError) do
      run_operation(HouseholdFinance::Operations::Baseline::Approve, request: input, coverage_status: "complete", base_version_id: nil, base_lock_version: 0, expected_preview_digest: preview[:digest], reason: "Attempted stale fictional baseline")
    end
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    assert_equal original_bytes, prior.reload.attributes
    identities = source[:accounts].each_with_index.map { |account, i| review_account(account, source[:facts], tracked: identities[i].source_tracked_account, prior: identities[i]) }
    approve_rows(source, identities)
    current = run_operation(OPS::RevisionApprove, coverage_input(source, identities))
    assert_equal prior.id, current.supersedes_id
    assert_equal "complete", current.coverage_status
    assert_baseline_complete(source, identities.first, first: "2026-07-01", last: "2026-07-31", expected_rows: 2)
  end

  test "old qualified grouped coverage remains historical and never becomes complete automatically" do
    source = small_source
    identities = review_accounts(source)
    approve_rows(source, identities)
    prior = with_legacy_reconciliation(source, identities) { run_operation(OPS::RevisionApprove, coverage_input(source, identities, status: "qualified")) }
    reader = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ source[:revision].id ])[:revisions].sole
    assert_equal "qualified", prior.reload.coverage_status
    assert_equal "stale", reader[:coverage_status]
    refute reader[:participant_approved]
    assert state(source)[:reconciliation][:accounts].sole[:arithmetic_balanced]
  end

  test "single-account prior approval retains its digest and structured history after source expiry" do
    assert_retained_history([ 2 ], legacy: true)
  end

  test "newly approved grouped statement retains structured history after source expiry" do
    assert_retained_history([ 1, 1 ], legacy: false)
  end

  test "qualified coverage accepts the exact UI attestation with one or both period endpoints explicitly unknown" do
    [ { "period_start_on" => nil }, { "period_end_on" => nil }, { "period_start_on" => nil, "period_end_on" => nil } ].each do |unknown|
      source = source([ [ -100, "purchase" ] ], sizes: [ 1 ])
      identities = review_accounts(source, overrides: { 0 => unknown })
      approve_rows(source, identities)
      assert_includes state(source)[:deficiencies], "account_period_unknown"
      assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
      approval = run_operation(OPS::RevisionApprove, coverage_input(source, identities, status: "qualified"))
      assert_equal "qualified", approval.coverage_status
      assert_includes approval.deficiencies, "account_period_unknown"
      unknown.each_key { |field| assert_nil approval.coverage_attestation["accounts"].sole[field] }
    end
  end

  test "qualified coverage cannot omit known dates or accept malformed dates while valid mismatches stay qualified" do
    source = source([ [ -100, "purchase" ] ], sizes: [ 1 ])
    identities = review_accounts(source)
    approve_rows(source, identities)
    [ nil, "2026-07-32", "not-a-date" ].each do |date|
      input = coverage_input(source, identities, status: "qualified")
      input[:coverage_attestation][:accounts].sole[:period_start_on] = date
      assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, input) }
    end
    assert_empty SourceRevisionApproval.where(household: @household)
    input = coverage_input(source, identities, status: "qualified")
    input[:coverage_attestation][:accounts].sole[:period_start_on] = "2026-07-02"
    approval = run_operation(OPS::RevisionApprove, input)
    assert_includes approval.deficiencies, "account_period_or_row_coverage_not_attested"
    assert_equal "qualified", approval.coverage_status
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, input.merge(requested_status: "complete")) }
  end

  test "nullable qualified coverage still rejects foreign identities and stale current periods" do
    source = source([ [ -100, "purchase" ] ], sizes: [ 1 ])
    identities = review_accounts(source, overrides: { 0 => { "period_start_on" => nil } })
    approve_rows(source, identities)
    input = coverage_input(source, identities, status: "qualified")
    foreign = Household.create!(created_by_user: @user, name: "Other fictional household")
    foreign.household_memberships.create!(user: @user, role: "partner")
    original_household = @household
    @household = foreign
    foreign_source = source([ [ -100, "purchase" ] ], sizes: [ 1 ])
    foreign_identity = review_accounts(foreign_source, overrides: { 0 => { "period_start_on" => nil } }).sole
    @household = original_household
    foreign_input = input.deep_dup
    foreign_input[:coverage_attestation][:accounts].sole[:identity_version_id] = foreign_identity.id
    assert_raises(ActiveRecord::RecordNotFound) { run_operation(OPS::RevisionApprove, foreign_input) }
    operation = OPS::RevisionApprove.new(@household, user: @user)
    prepared = operation.prepare(input)
    prior = identities.sole
    review_account(source[:accounts].sole, source[:facts], tracked: prior.source_tracked_account, prior: prior)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_raises(ArgumentError) { run_operation(OPS::RevisionApprove, input) }
    assert_empty SourceRevisionApproval.where(household: @household)
  end

  private

  def small_source = source(Array.new(6) { [ -100, "purchase" ] }, sizes: [ 3, 2, 1 ])

  def source(rows, sizes:, first: "2026-07-01", last: "2026-07-31")
    import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "fictional-fragments.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "fictional/#{SecureRandom.hex(8)}.pdf")
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    facts = { "period_start_on" => first, "period_end_on" => last, "opening_balance_cents" => 50000, "closing_balance_cents" => 50000 - rows.sum(&:first),
      "printed_debit_cents" => rows.sum { |amount, _| [ -amount, 0 ].max }, "printed_credit_cents" => rows.sum { |amount, _| [ amount, 0 ].max }, "printed_row_count" => rows.length, "printed_row_count_basis" => "posted" }
    accounts = sizes.each_index.map { |i| { account_key: "fragment-#{i}", account_basis: "liability" }.merge(i.zero? ? facts.except("printed_row_count_basis").symbolize_keys : {}) }
    events = []; offset = 0
    sizes.each_with_index do |size, i|
      rows.slice(offset, size).each_with_index do |(amount, type), row|
        events << { account_key: "fragment-#{i}", row_kind: "posted", event_type: type, signed_amount_cents: amount, posted_on: first,
          merchant: "Fictional merchant", locator: { page: i + 1, row: row + 1 } }
      end
      offset += size
    end
    normalized = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: accounts, events: events, reported_row_count: rows.length }, coverage: { expected_page_count: sizes.length, processed_pages: (1..sizes.length).to_a })
    result = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: normalized).call
    import.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: import, accounts: result[:revision].financial_source_accounts.order(:id).to_a, facts: facts)
  end

  def review_accounts(source, overrides: {}, separate: [], tracked: nil)
    source[:accounts].each_with_index.map do |account, i|
      identity = review_account(account, source[:facts].merge(overrides.fetch(i, {})), tracked: separate.include?(i) ? nil : tracked)
      tracked ||= identity.source_tracked_account
      identity
    end
  end

  def review_account(account, facts, tracked: nil, prior: nil)
    run_operation(OPS::AccountLink, source_account_id: account.id, account_basis: "liability", label: "Fictional card", tracked_account_id: tracked&.id,
      base_version_id: prior&.id, base_lock_version: prior&.source_account_review_head&.reload&.lock_version || 0, statement_facts: facts, reason: "Participant checked the full fictional statement header")
  end

  def approve_rows(source, identities, only_account_id: nil)
    source[:events].each do |event|
      next if only_account_id && event.financial_source_account_id != only_account_id
      identity = identities.find { |row| row.source_account_review_head.financial_source_account_id == event.financial_source_account_id }
      head = SourceReviewHead.find_by(financial_source_event: event)
      purchase = event.signed_amount_cents.negative? && event.event_type.in?(%w[purchase fee interest]) ? event.signed_amount_cents.abs : nil
      draft = run_operation(OPS::DraftStage, event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, reason: "Participant checked this physical fictional row", projection: { action: "none" },
        facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: event.event_type, signed_amount_cents: event.signed_amount_cents, purchase_amount_cents: purchase,
          posted_on: event.posted_on.iso8601, merchant: "Fictional merchant", budget_category_id: @category.id, overlap_disposition: "distinct" })
      run_operation(OPS::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
    end
  end

  def state(source) = FinancialDocuments::SourceReview::ApprovalState.new(@household, source[:revision]).call

  def coverage_input(source, identities, status: "complete")
    { revision_id: source[:revision].id, expected_digest: state(source)[:content_digest], requested_status: status, reason: "Participant checked every fictional row and declared limitations",
      coverage_attestation: { all_document_rows_accounted: true, accounts: identities.map { |identity| { source_account_id: identity.source_account_review_head.financial_source_account_id, identity_version_id: identity.id,
        period_start_on: identity.statement_facts["period_start_on"], period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: true } } } }
  end

  def baseline_request(source, identity, first:, last:)
    { window_start_on: first, window_end_on: last, revision_ids: [ source[:revision].id ], tracked_account_ids: [ identity.source_tracked_account_id ], household_scope_attested: true, cash_coverage: "not_used",
      category_eligibility: [ { budget_category_id: @category.id, eligible: true, recurrence: "unknown", reason: "Participant reviewed this fictional category" } ] }
  end

  def assert_baseline_complete(source, identity, first:, last:, expected_rows: 125)
    request = baseline_request(source, identity, first: first, last: last)
    preview = FinancialBaselines::Preview.new(@household, user: @user).call(request)
    assert preview[:complete_eligible], preview[:deficiencies].inspect
    assert_equal expected_rows, FinancialBaselines::Preview.presentation(preview)[:represented_row_count]
    head = FinancialBaselineHead.find_by(household: @household, participant_user: @user)
    operation = head&.approved_version_id ? HouseholdFinance::Operations::Baseline::Revise : HouseholdFinance::Operations::Baseline::Approve
    baseline = run_operation(operation, request: request, coverage_status: "complete", base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
      expected_preview_digest: preview[:digest], reason: "Participant approved the complete fictional baseline")
    assert_equal "complete", baseline.coverage_status
    assert_empty @household.household_transactions
  end

  def assert_retained_history(sizes, legacy:)
    source = source([ [ -100, "purchase" ], [ -100, "purchase" ] ], sizes: sizes)
    identities = review_accounts(source)
    approve_rows(source, identities)
    prior = if legacy
      with_legacy_reconciliation(source, identities) { run_operation(OPS::RevisionApprove, coverage_input(source, identities)) }
    else
      run_operation(OPS::RevisionApprove, coverage_input(source, identities))
    end
    assert_equal prior.digest, state(source)[:content_digest]
    source[:import].update!(source_deleted_at: Time.current, s3_key: nil, status: "source_deleted")
    reader = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ source[:revision].id ])[:revisions].sole
    assert reader[:participant_approved]
    assert_equal "complete", reader[:coverage_status]
    assert_equal prior.digest, reader[:content_digest]
    assert_includes state(source)[:deficiencies], "source_unavailable"
    assert_baseline_complete(source, identities.first, first: "2026-07-01", last: "2026-07-31", expected_rows: 2)
  end

  def with_legacy_reconciliation(source, identities)
    # Reproduce the prior deployed rule via actual approval operations, not by
    # forging immutable approval records or changing the current digest.
    accounts = source[:accounts].each_with_index.map do |account, i|
      identities[i].statement_facts.symbolize_keys.merge(source_key: account.source_key, account_basis: "liability", limitations: [])
    end
    events = source[:events].map { |event| { source_key: event.financial_source_account.source_key, row_kind: "posted", signed_amount_cents: event.signed_amount_cents } }
    legacy = FinancialDocuments::SourceReconciliation.new(contract_version: source[:revision].contract_version, accounts: accounts, events: events, coverage: source[:revision].coverage).call
    klass = FinancialDocuments::SourceReview::ReviewedReconciliation
    original = klass.instance_method(:call)
    klass.define_method(:call) { legacy }
    yield
  ensure
    klass&.define_method(:call, original) if original
  end

  def run_operation(klass, input)
    operation = klass.new(@household, user: @user)
    prepared = operation.prepare(input)
    ApplicationRecord.transaction do
      result = operation.execute!(prepared, source: "manual")
      operation.send(:verify_after!, prepared.predicted_after_snapshot, operation.after_snapshot(result, prepared))
      result
    end
  end
end
