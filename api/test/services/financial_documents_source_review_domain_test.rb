require "test_helper"

class FinancialDocumentsSourceReviewDomainTest < ActiveSupport::TestCase
  OPS = HouseholdFinance::Operations::SourceReview

  setup do
    @user = User.create!(clerk_id: "source-review-#{SecureRandom.hex(8)}", email: "source-review-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic source review")
    @household.household_memberships.create!(user: @user, role: "owner")
    @category = @household.budget_categories.create!(name: "Synthetic groceries", stack_key: "non_discretionary", sort_order: 0)
    @source = source([ movement(-1_000) ])
    @identity = link(@source)
  end

  test "reviewed zero activity statement can be complete while a blank or hidden movement cannot" do
    @source = source([ movement(0, type: "unknown") ])
    account = account_input(@source)
    @identity = run_operation(OPS::AccountLink, account.merge(statement_facts: account[:statement_facts].merge("printed_row_count_basis" => "all")))
    approve(stage(@source[:events].sole, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    approval = attest("complete")
    assert_equal "complete", approval.coverage_status
    assert_empty approval.deficiencies
    hidden = source([ movement(-100) ])
    identity = link(hidden)
    approve(stage(hidden[:events].sole, identity: identity, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, hidden[:revision]).call
    assert_includes state[:deficiencies], "empty_source_history"
    assert_includes state[:deficiencies], "account_reconciliation_incomplete"
  end

  test "staging and cancelling do not change actuals or hide an approved head" do
    approved = approve(stage(@source[:events].first))
    head = approved.source_review_head
    draft = stage(@source[:events].first, amount: -900)
    assert_equal approved.id, head.reload.approved_version_id
    assert_equal 1_000, reader[:rows].sole[:purchase_amount_cents]
    assert_equal 1, reader[:revisions].sole[:state][:pending_corrections]
    assert_empty @household.household_transactions
    run_operation(OPS::DraftCancel, draft_input(draft))
    assert_equal "cancelled", draft.reload.status
    assert_equal approved.id, head.reload.approved_version_id
  end

  test "approved corrections append facts and preserve original immutable extraction" do
    original = @source[:events].first
    first = approve(stage(original))
    second = approve(stage(original, amount: -900, reason: "Corrected from the synthetic source page"))
    assert_equal first.id, second.supersedes_id
    assert_equal 2, second.version_number
    assert_equal(-1_000, original.reload.signed_amount_cents)
    assert_equal(-1_000, first.reload.signed_amount_cents)
    assert_equal(-900, second.signed_amount_cents)
    assert_raises(ActiveRecord::ReadOnlyRecord) { second.update!(signed_amount_cents: -800) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewVersion.where(id: second.id).update_all(signed_amount_cents: -800) }
    end
    original.financial_source_evidence.destroy!
    assert_equal "Synthetic merchant", second.reload.merchant
  end

  test "stale proposal fingerprints fail before changing approved versions" do
    draft = stage(@source[:events].first)
    operation = OPS::DraftApprove.new(@household, user: @user)
    prepared = operation.prepare(draft_input(draft))
    stage(@source[:events].first, amount: -900)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_nil draft.source_review_head.reload.approved_version_id
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "current participant writable permission is checked again at execution and replay" do
    draft = stage(@source[:events].first)
    operation = OPS::DraftApprove.new(@household, user: @user)
    prepared = operation.prepare(draft_input(draft))
    @user.update!(role: "coach")
    assert_raises(ArgumentError) { operation.execute!(prepared, source: "manual") }
    @user.update!(role: "participant")
    approved = approve(draft)
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    assert_raises(ArgumentError) { operation.authorize_replay!(approved) }
    assert OPS::DraftApprove::ACTOR_REQUIRED
    assert OPS::DraftApprove::SENSITIVE_AUDIT
  end

  test "unknown rows cannot silently become approved posted facts but informational exclusions are reviewed" do
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: nil) }
    assert_raises(ArgumentError) { stage(@source[:events].first, event_type: "refund", amount: -1_000) }
    approved = approve(stage(@source[:events].first, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    assert_equal "informational", approved.disposition
    assert_nil approved.signed_amount_cents
    assert_empty @household.household_transactions
  end

  test "explicit expense replacement preserves old positive amounts and voiding never creates negative spending" do
    first = approve(stage(@source[:events].first, projection: { action: "create" }))
    old = first.source_projection_revision.replacement_transaction
    assert_equal 1_000, old.total_amount_cents
    second = approve(stage(@source[:events].first, amount: -900, projection: { action: "replace", transaction_id: old.id, expected_digest: FinancialDocuments::SourceReview::ProjectionCorrector.snapshot_digest(old) }))
    replacement = second.source_projection_revision.replacement_transaction
    assert_equal 900, replacement.total_amount_cents
    assert_equal "ignored", old.reload.status
    assert_equal 1_000, old.total_amount_cents
    third = approve(stage(@source[:events].first, disposition: "exclude", overlap: "excluded", projection: { action: "void", transaction_id: replacement.id, expected_digest: FinancialDocuments::SourceReview::ProjectionCorrector.snapshot_digest(replacement) }))
    assert_nil third.source_projection_revision.replacement_transaction
    assert_equal "ignored", replacement.reload.status
    assert_equal [ 900, 1_000 ], @household.household_transactions.order(:total_amount_cents).pluck(:total_amount_cents)
  end

  test "source account identity is reviewed across months and remapping marks previous facts stale" do
    approved = approve(stage(@source[:events].first))
    second_source = source([ movement(-500, posted_on: "2026-08-07") ], period: "2026-08")
    second_identity = link(second_source, tracked: @identity.source_tracked_account)
    assert_equal @identity.source_tracked_account_id, second_identity.source_tracked_account_id
    head = @identity.source_account_review_head
    run_operation(OPS::AccountLink, account_input(@source).merge(base_version_id: @identity.id, base_lock_version: head.reload.lock_version, label: "Corrected separate account"))
    refute reader[:rows].sole[:account_identity_current]
    assert_equal approved.id, reader[:rows].sole[:id]
    assert_includes reader[:revisions].sole[:state][:deficiencies], "account_identity_changed"
  end

  test "pending exact copies require canonical choice and cannot both create spending" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    copy_identity = link(copy, tracked: @identity.source_tracked_account)
    first_draft = stage(@source[:events].first, overlap: "canonical", projection: { action: "create" })
    second_draft = stage(copy[:events].first, identity: copy_identity, overlap: "canonical", projection: { action: "create" })
    first = approve(first_draft)
    assert_raises(ArgumentError) { approve(second_draft) }
    matched = approve(stage(copy[:events].first, identity: copy_identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    assert_equal first.id, matched.matched_version_id
    assert_equal 1, @household.household_transactions.count
  end

  test "date and amount alone are ambiguous while repeated genuine rows on one file survive" do
    other = source([ movement(-1_000) ])
    other_identity = link(other, tracked: @identity.source_tracked_account)
    assert_raises(ArgumentError) { approve(stage(@source[:events].first)) }
    first = approve(stage(@source[:events].first, overlap: "distinct"))
    second = approve(stage(other[:events].first, identity: other_identity, overlap: "distinct"))
    assert_equal "include", first.disposition
    assert_equal "include", second.disposition
    genuine = source([ movement(-200, row: 1), movement(-200, row: 2) ], period: "2026-09")
    genuine_identity = link(genuine)
    genuine[:events].each { |event| approve(stage(event, identity: genuine_identity, amount: -200, posted_on: "2026-09-07")) }
    assert_equal 2, SourceReviewVersion.joins(:source_review_head).where(source_review_heads: { financial_source_event_id: genuine[:events].map(&:id) }).count
  end

  test "complete source approval requires every current version and explicit coverage with balanced reviewed headers" do
    assert_raises(ArgumentError) { attest("complete") }
    approved = approve(stage(@source[:events].first))
    coverage = attest("complete")
    assert_equal "complete", coverage.coverage_status
    assert reader[:revisions].sole[:participant_approved]
    draft = stage(@source[:events].first, amount: -900)
    assert_equal "complete", reader[:revisions].sole[:coverage_status]
    approve(draft)
    assert_equal "stale", reader[:revisions].sole[:coverage_status]
    assert_equal [ approved.id ], coverage.source_version_ids
    assert_raises(ArgumentError) { attest("complete") }
    qualified = attest("qualified")
    assert_equal "qualified", qualified.coverage_status
    assert_includes qualified.deficiencies, "account_reconciliation_incomplete"
  end

  test "unknown page coverage and deleted evidence cannot be newly called complete" do
    approve(stage(@source[:events].first))
    @source[:import].update!(source_deleted_at: Time.current, s3_key: nil, status: "source_deleted")
    assert_raises(ArgumentError) { attest("complete") }
    assert_equal "qualified", attest("qualified").coverage_status
    assert_equal(-1_000, reader[:rows].sole[:signed_amount_cents])
  end

  test "transfer pairing requires participant-approved opposing legs and rejects over-allocation" do
    bank = approve(stage(@source[:events].first, event_type: "transfer", purchase: nil))
    received_source = source([ movement(1_000, type: "transfer", posted_on: "2026-07-08") ])
    received_identity = link(received_source)
    received = approve(stage(received_source[:events].first, identity: received_identity, amount: 1_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    members = [ { source_review_version_id: bank.id, role: "movement", allocation_cents: 1_000 }, { source_review_version_id: received.id, role: "movement", allocation_cents: 1_000 } ]
    group = run_operation(OPS::EconomicLink, group_input("transfer", members))
    assert_equal "transfer", group.kind
    assert_empty @household.household_transactions
    assert_raises(ArgumentError) { run_operation(OPS::EconomicLink, group_input("transfer", members)) }
    refute reader[:rows].sole[:spending_eligible]
  end

  test "split funding stages one full purchase only after a reviewed economic link" do
    wallet = approve(stage(@source[:events].first, amount: -1_000, purchase: 10_000))
    refute reader[:rows].sole[:spending_eligible]
    assert_raises(ArgumentError) { project(wallet) }
    funding_source = source([ movement(-9_000, type: "transfer", posted_on: "2026-07-08") ])
    funding_identity = link(funding_source)
    funding = approve(stage(funding_source[:events].first, identity: funding_identity, amount: -9_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    run_operation(OPS::EconomicLink, group_input("purchase_funding", [ { source_review_version_id: wallet.id, role: "purchase", allocation_cents: 1_000 }, { source_review_version_id: funding.id, role: "funding", allocation_cents: 9_000 } ]))
    assert reader[:rows].sole[:spending_eligible]
    projected = project(wallet)
    assert_equal 10_000, projected.replacement_transaction.total_amount_cents
    assert_equal 1, @household.household_transactions.count
  end

  test "matching aliases resolve one canonical fact and become stale when that target changes" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    identity = link(copy, tracked: @identity.source_tracked_account)
    first = approve(stage(@source[:events].first, overlap: "canonical"))
    alias_version = approve(stage(copy[:events].first, identity: identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    view = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ copy[:revision].id ])
    assert_equal [ alias_version.id ], view[:rows].pluck(:id)
    assert_equal [ first.id ], view[:canonical_rows].pluck(:id)
    assert_equal [ @source[:revision].id ], view[:dependency_revision_ids]
    before = FinancialDocuments::SourceReview::ApprovalState.new(@household, copy[:revision]).call
    approve(stage(@source[:events].first, amount: -900))
    after = FinancialDocuments::SourceReview::ApprovalState.new(@household, copy[:revision]).call
    refute_equal before[:content_digest], after[:content_digest]
    assert_includes after[:deficiencies], "matched_source_fact_changed"
    assert_empty FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ copy[:revision].id ])[:canonical_rows]
  end

  test "economic link changes stale prior coverage while pending correction does not" do
    bank = approve(stage(@source[:events].first, event_type: "transfer", purchase: nil))
    attest("complete")
    other = source([ movement(1_000, type: "transfer", posted_on: "2026-07-08") ])
    identity = link(other)
    received = approve(stage(other[:events].first, identity: identity, amount: 1_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    run_operation(OPS::EconomicLink, group_input("transfer", [ { source_review_version_id: bank.id, role: "movement", allocation_cents: 1_000 }, { source_review_version_id: received.id, role: "movement", allocation_cents: 1_000 } ]))
    assert_equal "stale", reader[:revisions].find { |row| row[:id] == @source[:revision].id }[:coverage_status]
    assert_equal 1, reader[:economic_groups].length
  end

  test "refunds retain positive inflow and never create positive spending" do
    original = approve(stage(@source[:events].first))
    credit = source([ movement(500, type: "refund", posted_on: "2026-07-08") ])
    identity = link(credit, tracked: @identity.source_tracked_account)
    refunded = approve(stage(credit[:events].first, identity: identity, amount: 500, purchase: nil, event_type: "refund", posted_on: "2026-07-08"))
    group = run_operation(OPS::EconomicLink, group_input("refund", [ { source_review_version_id: original.id, role: "original_purchase", allocation_cents: 500 }, { source_review_version_id: refunded.id, role: "refund", allocation_cents: 500 } ]))
    assert_equal "refund", group.kind
    assert_equal 500, refunded.signed_amount_cents
    assert_raises(ArgumentError) { project(refunded) }
    assert_empty @household.household_transactions
  end

  test "strict dates cents direction and projection actions fail without mutation" do
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: -10.5) }
    assert_raises(ArgumentError) { stage(@source[:events].first, posted_on: "2026-08-01") }
    assert_raises(ArgumentError) { stage(@source[:events].first, posted_on: "July 7, 2026") }
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: 1_000) }
    assert_raises(ArgumentError) { OPS::DraftStage.new(@household, user: @user).prepare(event_id: @source[:events].first.id, base_version_id: nil, base_lock_version: 0, facts: {}, projection: { action: "create", transaction_id: 1 }, reason: "Synthetic reason") }
    assert_empty SourceReviewVersion.where(household: @household)
  end

  test "inactive categories and failed projection roll back an approval atomically" do
    draft = stage(@source[:events].first, projection: { action: "create" })
    @category.update!(active: false)
    assert_raises(ArgumentError) { approve(draft) }
    assert_equal "pending", draft.reload.status
    assert_nil draft.source_review_head.reload.approved_version_id
    assert_empty @household.household_transactions
    assert_empty SourceReviewVersion.where(household: @household)
  end

  test "cross household IDs and SQL approved head substitution fail closed" do
    foreign = Household.create!(created_by_user: @user, name: "Other synthetic household")
    foreign.household_memberships.create!(user: @user, role: "partner")
    assert_raises(ActiveRecord::RecordNotFound) { OPS::DraftApprove.new(foreign, user: @user).prepare(draft_input(stage(@source[:events].first))) }
    first = approve(stage(@source[:events].first))
    second_source = source([ movement(-200, row: 2) ])
    identity = link(second_source)
    second = approve(stage(second_source[:events].first, identity: identity, amount: -200))
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewHead.where(id: first.source_review_head_id).update_all(approved_version_id: second.id) }
    end
    assert_raises(ArgumentError) { OPS::DraftApprove.new(foreign, user: @user).authorize_replay!(first) }
    assert_equal first.id, first.source_review_head.reload.approved_version_id
  end

  test "unknown page coverage remains qualified despite balanced reviewed financial facts" do
    original = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic-unknown.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf")
    attempt = original.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    contract = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [ { account_key: "unknown", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31", opening_balance_cents: 20_000, closing_balance_cents: 19_000, printed_debit_cents: 1_000, printed_credit_cents: 0 } ], events: [ movement(-1_000).merge(account_key: "unknown") ] })
    @source = FinancialDocuments::SourceAccountingPersister.new(original, attempt: attempt, accounting: contract).call.merge(import: original)
    @identity = link(@source)
    approve(stage(@source[:events].first, overlap: "distinct"))
    assert_raises(ArgumentError) { attest("complete") }
    assert_includes attest("qualified").deficiencies, "document_page_or_sheet_coverage_unverified"
  end

  test "canonical account optional ledger link survives reuse and can be nullified without erasing reviewed facts" do
    account = @household.accounts.create!(label: "Synthetic checking ledger", account_type: "checking")
    head = @identity.source_account_review_head
    linked = run_operation(OPS::AccountLink, account_input(@source).merge(base_version_id: @identity.id, base_lock_version: head.reload.lock_version, account_id: account.id))
    extra = source([ movement(-400) ], period: "2026-08")
    reused = link(extra, tracked: linked.source_tracked_account)
    assert_equal account.id, reused.source_tracked_account.account_id
    account.destroy!
    assert_nil linked.source_tracked_account.reload.account_id
    assert_equal "asset", linked.source_tracked_account.account_basis
    assert_equal linked.id, linked.source_account_review_head.reload.approved_version_id
  end

  test "logical review head identity cannot be switched by SQL" do
    first = approve(stage(@source[:events].first))
    extra = source([ movement(-400) ], period: "2026-08")
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewHead.where(id: first.source_review_head_id).update_all(financial_source_event_id: extra[:events].first.id) }
    end
    assert_equal @source[:events].first.id, first.source_review_head.reload.financial_source_event_id
  end

  test "correction flags all affected coverage and matched imports as requiring renewed review" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    identity = link(copy, tracked: @identity.source_tracked_account)
    first = approve(stage(@source[:events].first, overlap: "canonical"))
    approve(stage(copy[:events].first, identity: identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    copy[:import].update!(metadata: copy[:import].metadata.merge("source_accounting_review_pending" => false))
    approve(stage(@source[:events].first, amount: -900))
    assert copy[:import].reload.metadata["source_accounting_review_pending"]
    assert @source[:import].reload.metadata["source_accounting_review_pending"]
  end

  test "baseline reader digest pins the exact declared coverage version" do
    approve(stage(@source[:events].first))
    attest("complete")
    first = reader
    refute_includes first[:revisions].sole[:state][:reconciliation][:accounts].sole[:limitations], "printed_row_count_unknown"
    attest("complete")
    second = reader
    refute_equal first[:revisions].sole[:approval_id], second[:revisions].sole[:approval_id]
    refute_equal first[:digest], second[:digest]
    assert_equal first[:revisions].sole[:content_digest], second[:revisions].sole[:content_digest]
  end

  test "typed source rows stay in source review while manual drafts remain in the legacy queue" do
    typed = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 7, 7), merchant: "Typed source row",
      total_amount_cents: 1000, source_type: "statement", status: "pending", financial_source_event: @source[:events].sole,
      financial_document_import: @source[:import])
    manual = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 7, 7), merchant: "Manual reported row",
      total_amount_cents: 1000, source_type: "manual_chat", status: "pending")
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).plan_data
    assert_equal [ manual.id ], plan.fetch(:pending_transaction_drafts).pluck(:id)
    assert_equal 1, plan.fetch(:pending_transaction_drafts_meta).fetch(:total_count)
    assert_equal "pending", typed.reload.status
    assert_empty @household.household_transactions
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

  def movement(amount, row: 1, type: "purchase", posted_on: "2026-07-07")
    { account_key: "synthetic-account", row_kind: "posted", event_type: type, signed_amount_cents: amount, posted_on: posted_on, merchant: "Synthetic merchant", locator: { page: 1, row: row } }
  end

  def source(rows, checksum: SecureRandom.hex(32), period: "2026-07")
    import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: checksum)
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    rows = rows.map { |row| row.merge(posted_on: period + "-07") } if period != "2026-07"
    net = rows.sum { |row| row[:signed_amount_cents] }
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: "asset", period_start_on: period + "-01", period_end_on: Date.iso8601(period + "-01").end_of_month.iso8601, opening_balance_cents: 20_000, closing_balance_cents: 20_000 + net,
        printed_debit_cents: rows.sum { |row| [ -row[:signed_amount_cents], 0 ].max }, printed_credit_cents: rows.sum { |row| [ row[:signed_amount_cents], 0 ].max }, printed_row_count: rows.length } ], events: rows, reported_row_count: rows.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    import.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: import)
  end

  def account_input(source)
    account = source[:revision].financial_source_accounts.sole
    { source_account_id: account.id, account_basis: "asset", label: "Synthetic checking", base_version_id: nil, base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Participant verified synthetic account and header" }
  end

  def link(source, tracked: nil)
    run_operation(OPS::AccountLink, account_input(source).merge(tracked_account_id: tracked&.id))
  end

  def stage(event, identity: @identity, amount: -1_000, purchase: :default, posted_on: "2026-07-07", event_type: "purchase", disposition: "include", overlap: "new", matched_version_id: nil, reason: "Participant reviewed the synthetic row", projection: { action: "none" })
    head = SourceReviewHead.find_by(household: @household, financial_source_event: event)
    purchase = amount&.abs if purchase == :default
    pending = head&.source_review_drafts&.pending&.first
    run_operation(OPS::DraftStage, { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, expected_pending_draft: pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest }, reason: reason, projection: projection,
      facts: { source_account_identity_version_id: identity.id, disposition: disposition, event_type: event_type, signed_amount_cents: amount, purchase_amount_cents: purchase, posted_on: posted_on,
        merchant: "Synthetic merchant", budget_category_id: @category.id, overlap_disposition: overlap, matched_version_id: matched_version_id } })
  end

  def draft_input(draft)
    draft.reload
    { draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest }
  end

  def approve(draft) = run_operation(OPS::DraftApprove, draft_input(draft))
  def reader = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ @source[:revision].id ])
  def group_input(kind, members) = { kind: kind, members: members, base_version_id: nil, base_lock_version: 0, reason: "Participant explicitly verified the synthetic economic link" }

  def project(version)
    run_operation(OPS::ExpenseProject, version_id: version.id, expected_version_digest: version.digest, projection: { action: "create" }, reason: "Participant separately approved positive spending")
  end

  def attest(status)
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, @source[:revision]).call
    identity = SourceAccountReviewHead.find_by!(financial_source_account: @source[:revision].financial_source_accounts.sole).approved_version
    run_operation(OPS::RevisionApprove, revision_id: @source[:revision].id, expected_digest: state[:content_digest], requested_status: status, reason: "Participant declared reviewed coverage and limitations",
      coverage_attestation: { all_document_rows_accounted: true, accounts: [ { source_account_id: identity.source_account_review_head.financial_source_account_id, identity_version_id: identity.id,
        period_start_on: identity.statement_facts["period_start_on"], period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: true } ] })
  end
end
