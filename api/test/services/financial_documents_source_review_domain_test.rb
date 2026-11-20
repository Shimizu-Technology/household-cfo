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

  test "previous default category is ready as before on the next statement" do
    @category.update!(name: "Everyday spending", stack_key: "discretionary")
    approve(stage(@source[:events].sole, merchant: "Ross"))
    fresh = source([ movement(-1200) ])
    event = fresh[:events].sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => "Ross"))
    link(fresh)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision]).lines.sole
    assert line.ready?, line.kind.inspect
    assert line.as_before
    assert_equal @category.id, line.category_id
  end

  test "review one answer covers similar statement merchants after an explicit different split" do
    @household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary")
    fresh = source([ movement(-3500).merge(merchant: "Payless"), movement(-4100, row: 2).merge(merchant: "Cost-U-Less") ])
    identity = link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal 2, plan.attention.length
    approve(stage(fresh[:events].first, identity: identity, amount: -3500, merchant: "Payless"))
    after = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    other = after.line_for(fresh[:events].last.id)
    assert other.ready?, other.kind.inspect
    assert_equal @category.id, other.category_id
    assert_equal 1, after.lines.count(&:done)
  end

  test "review grocery and fuel statement lines use the everyday default despite an extracted bills label" do
    @category.update!(name: "Fixed essentials")
    everyday = @household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary")
    merchants = [ "Payless", "Cost-U-Less", "Shell", "Mobil" ]
    fresh = source(merchants.map.with_index { |merchant, i| movement(-3500 - i * 100, row: i + 1).merge(merchant: merchant) })
    payloads = fresh[:transaction_drafts].map do |payload|
      payload.merge(splits: [ { amount: payload[:total_amount], category_name: "Fixed essentials", stack_key: "non_discretionary", confidence: "high" } ])
    end
    result = HouseholdFinance::DocumentTransactionDraftPersister.new(fresh[:import], payloads).call
    assert_equal 4, result[:created_count]
    identity = link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal fresh[:events].map(&:id), plan.ready_ids
    assert_empty plan.attention
    plan.lines.each do |line|
      assert line.ready?
      assert_equal everyday.id, line.category_id
    end
    assert_empty @household.household_transactions

    # Her reviewed choice still takes priority on the next statement.
    @category = everyday
    approve(stage(fresh[:events].first, identity: identity, amount: -3500, merchant: "Payless"))
    next_source = source([ movement(-4500).merge(merchant: "Payless") ])
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, next_source[:revision]).lines.sole
    assert line.ready?
    assert line.as_before
    assert_equal everyday.id, line.category_id
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

  # Review of #197 (M1): spending approved through source review creates a
  # confirmed actual and flips only pending drafts, so an import whose
  # drafts were ignored first still holds approved values.
  test "source review approvals count as approved values for status, guards and Mia" do
    fresh = source([ movement(-1_000) ])
    import = fresh[:import]
    staged = HouseholdFinance::DocumentTransactionDraftPersister.new(import, fresh[:transaction_drafts]).call
    assert_equal 1, staged[:created_count]
    import.transaction_drafts.sole.update!(status: "ignored")
    refute import.approved_values?

    identity = link(fresh)
    assert import.approved_values?, "an approved account identity is an approved value"
    project(approve(stage(fresh[:events].sole, identity: identity)))
    actual = @household.household_transactions.find_by!(source_import: import)
    assert_equal "confirmed", actual.status
    assert_equal "ignored", import.transaction_drafts.sole.reload.status
    @identity = identity
    @source = fresh
    attest("qualified")

    import.update!(metadata: import.metadata.merge("source_accounting_review_pending" => false))
    HouseholdFinance::DocumentImportStatusReconciler.new(import).call
    assert_equal "applied", import.reload.status
    assert_includes @household.financial_document_imports.with_approved_values, import
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

  test "participant merchant wording survives staging approval read-back and spending projection" do
    merchant = "Ross Dress for Less"
    draft = stage(@source[:events].sole, merchant: merchant)
    assert_equal merchant, draft.facts["merchant"]
    version = approve(draft)
    assert_equal merchant, version.reload.merchant
    assert_equal merchant, reader[:rows].sole[:merchant]
    assert_equal merchant, reader[:canonical_rows].sole[:merchant]
    project(version)
    assert_equal merchant, @household.household_transactions.sole.merchant

    corrected = approve(stage(@source[:events].sole, merchant: "CARD PURCHASE 1776 COFFEE", reason: "Participant corrected the merchant"))
    assert_equal "CARD PURCHASE 1776 COFFEE", corrected.reload.merchant
    assert_equal "CARD PURCHASE 1776 COFFEE", reader[:rows].sole[:merchant]
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
    @user.update!(invitation_status: "revoked")
    assert_raises(ArgumentError) { operation.execute!(prepared, source: "manual") }
    @user.update!(invitation_status: "accepted")
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

  test "review person detector excludes merchants billers and debt and keeps edited categories" do
    [ [ "PAYPAL *EBAY.COM", "purchase", false ], [ "PAYPAL *NETFLIX.COM", "purchase", false ], [ "Payment to Guam Power Authority", "purchase", false ], [ "Payment to Chase card ending 1234", "debt_payment", false ], [ "Zelle to Ana Cruz", "purchase", true ] ].each do |merchant, type, person|
      payment = source([ movement(-4599, type: type).merge(merchant: merchant) ])
      link(payment)
      event = payment[:events].sole
      assert_equal person, FinancialDocuments::SourceReview::TransferPairs.person_payment?(event, merchant), merchant
      line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
      assert_equal :card_payment, line.kind if type == "debt_payment"
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      input = { lines: [ { event_id: event.id, decision: "edited", expected_head: line.expected_head,
        edit: { kind: type == "debt_payment" ? "card" : "spending", category_id: @category.id } } ] }
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
      assert_equal @category.id, domain.heads.find_by!(financial_source_event: event).approved_version.budget_category_id unless type == "debt_payment"
    end
  end

  test "an explicit category on a person-worded line is never replaced" do
    payment = source([ movement(-4599).merge(merchant: "Payment to Ana Cruz") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    entry = { event_id: line.event.id, decision: "edited", expected_head: line.expected_head, edit: { kind: "spending", category_id: @category.id } }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], { lines: [ entry ] }).call }
    assert_equal @category.id, domain.heads.find_by!(financial_source_event: line.event).approved_version.budget_category_id
  end

  test "incoming person wording and open spreadsheet directions cannot be paired away" do
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer").merge(merchant: "Zelle from Mom") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    pairs = FinancialDocuments::SourceReview::TransferPairs
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    event = credit[:events].sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => "Transfer from checking"))
    assert pairs.new(@household).candidate(debit[:events].sole)
    blocked = source([ movement(2800, type: "transfer") ], coverage: { signed_amount_question: true })
    outgoing = source([ movement(-2800, type: "transfer") ])
    link(outgoing)
    run_operation(OPS::AccountLink, account_input(blocked).merge(label: "Talun blocked savings"))
    assert_nil pairs.new(@household).candidate(outgoing[:events].sole)
    multi = source([ movement(3200, type: "transfer"), movement(nil, row: 2, type: "unknown").merge(account_key: "unclear-account", limitations: [ "transaction_direction_unclear" ], source_amount_text: "25.00") ],
      extra_accounts: [ { account_key: "unclear-account", account_basis: "asset" } ])
    multi[:import].update!(filename: "multi.csv", content_type: "text/csv")
    clear_account = multi[:events].find { |event| event.signed_amount_cents == 3200 }.financial_source_account
    run_operation(OPS::AccountLink, { source_account_id: clear_account.id, account_basis: "asset", label: "Talun multi savings", base_version_id: nil, base_lock_version: 0, statement_facts: {}, reason: "Verified synthetic account" })
    questions = FinancialDocuments::SpreadsheetSignAnswer.account_questions(multi[:revision])
    assert_equal 1, questions.length
    assert questions.sole[:answerable]
    other_debit = source([ movement(-3200, type: "transfer") ])
    link(other_debit)
    assert_nil pairs.new(@household).candidate(other_debit[:events].sole)
    refute FinancialDocuments::SpreadsheetSignAnswer.saved_decisions?(multi[:revision])
  end

  test "scorecard reviews an unmatched pair separately even without corrections or a mapping" do
    require Rails.root.join("lib/scorecard/approval_simulator")
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    key = Object.new
    def key.event(answer) = answer.fetch("expected")
    simulator = Scorecard::ApprovalSimulator.new(household: @household, user: @user, answer_key: key, categories: {}, correct_proposals: false)
    answer = { "leg_id" => "outgoing", "signed_amount_cents" => -2500, "date" => "2026-07-07", "expected" => { "event_kind" => "transfer_own_accounts" } }
    simulator.row_answers[credit[:events].sole.id] = { "expected" => { "event_kind" => "purchase" } }
    [ answer, nil ].each do |mapping|
      entry = simulator.send(:answer_for, line, mapping, "2026-07")
      assert_equal "edited", entry[:decision]
      assert_equal "moved", entry[:edit][:kind]
    end
  end

  test "participant pairs opposing reviewed accounts and can unpair without spending" do
    debit = source([ movement(-2500, type: "purchase").merge(merchant: "Zelle to Lina Talun") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision])
    line = plan.lines.sole
    assert_equal :transfer_pair, line.kind
    pair = line.pair
    prompt = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, debit[:revision], user: @user).context(event_ids: [ line.event.id ])
    assert_equal FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(pair[:event]), prompt[:plan][:attention].sole[:transfer_pair][:description]
    input = { lines: [ { event_id: line.event.id, decision: "pair_transfer", expected_head: line.expected_head,
      shown: { event_type: "purchase", category_id: nil }, transfer_pair: { event_id: pair[:event].id, approved_version_id: nil, account_version_id: pair[:identity].id } } ] }
    stale = input.deep_dup
    stale[:lines].first[:transfer_pair][:account_version_id] += 1
    assert_raises(FinancialDocuments::SourceReview::Domain::StaleReview) do
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], stale).call }
    end
    assert_empty domain.heads.where(financial_source_event: debit[:events].sole)
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], input).call }
    group = FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(line.event)
    assert_equal 2, group.source_economic_memberships.count
    presented = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, debit[:revision], user: @user).context(event_ids: [ line.event.id ])
    assert_equal line.event.id, presented[:transfer_pairs].sole[:event_id]
    retry_result = @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], input).call }
    assert_equal 2, retry_result[:unchanged]
    assert_empty @household.household_transactions
    fresh = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], { lines: [ { event_id: line.event.id, decision: "unpair_transfer", expected_head: fresh.expected_head } ] }).call }
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(line.event)
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).candidate(line.event)
    reopened = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    refute reopened.done
    assert_equal :person_payment, reopened.kind
    assert_empty @household.household_transactions
  end

  test "transfer suggestions refuse ambiguous same account and distant movements" do
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit, tracked: @identity.source_tracked_account)
    link(credit, tracked: @identity.source_tracked_account)
    pairs = FinancialDocuments::SourceReview::TransferPairs
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    head = SourceAccountReviewHead.find_by!(financial_source_account: credit[:revision].financial_source_accounts.sole)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412", base_version_id: head.approved_version_id, base_lock_version: head.lock_version))
    assert pairs.new(@household).candidate(debit[:events].sole)
    duplicate = source([ movement(2500, type: "transfer") ])
    run_operation(OPS::AccountLink, account_input(duplicate).merge(label: "Talun wallet"))
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    distant_debit = source([ movement(-4000, type: "transfer") ])
    distant_credit = source([ movement(4000, type: "transfer", posted_on: "2026-07-12") ])
    link(distant_debit, tracked: @identity.source_tracked_account)
    run_operation(OPS::AccountLink, account_input(distant_credit).merge(label: "Talun distant savings"))
    assert_nil pairs.new(@household).candidate(distant_debit[:events].sole)
  end

  test "own account answer removes a proposed purchase from pending Budget without spending" do
    payment = source([ movement(-1500).merge(merchant: "Venmo to Talun wallet") ])
    link(payment)
    event = payment[:events].sole
    draft = @household.transaction_drafts.create!(financial_source_event: event, financial_document_import: payment[:import],
      occurred_on: event.posted_on, merchant: "Venmo to Talun wallet", total_amount_cents: 1500, source_type: "statement", status: "pending", draft_payload: {})
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    input = { lines: [ { event_id: event.id, decision: "own_account", expected_head: line.expected_head, shown: { event_type: "purchase", category_id: line.category_id } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    assert_equal "ignored", draft.reload.status
    assert_equal "transfer", domain.heads.find_by!(financial_source_event: event).approved_version.event_type
    assert_empty @household.household_transactions
  end

  test "an archived support category gives a plain recovery and leaves the payment unanswered" do
    @household.budget_categories.create!(name: "Family Support", stack_key: "non_discretionary", active: false)
    payment = source([ movement(-3500, type: "transfer").merge(merchant: "Zelle to Lina Talun") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    error = assert_raises(ArgumentError) do
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], { lines: [ { event_id: line.event.id, decision: "someone_else", expected_head: line.expected_head, shown: { event_type: "transfer", category_id: nil } } ] }).call }
    end
    assert_equal "Restore Family support in Budget, then save this answer.", error.message
    assert_empty domain.heads.where(financial_source_event: line.event)
    assert_empty @household.household_transactions
  end

  test "a different person payment still requires ownership instead of accepting a spending guess" do
    earlier = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    identity = link(earlier, tracked: @identity.source_tracked_account)
    approve(stage(earlier[:events].sole, identity: identity, amount: -3500, merchant: "Zelle to Lina Talun"))
    payment = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    link(payment, tracked: @identity.source_tracked_account)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :person_payment_duplicate, line.kind
    input = { lines: [ { event_id: line.event.id, decision: "own_account", expected_head: line.expected_head, shown: { event_type: "purchase", category_id: line.category_id } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    version = domain.heads.find_by!(financial_source_event: line.event).approved_version
    assert_equal "transfer", version.event_type
    assert_equal "distinct", version.overlap_disposition
    assert_empty @household.household_transactions
  end

  test "own account keeps a reviewed card payment as a card payment" do
    payment = source([ movement(-1500, type: "debt_payment").merge(merchant: "Payment to Talun card") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :card_payment, line.kind
    input = { lines: [ { event_id: line.event.id, decision: "as_read", expected_head: line.expected_head, shown: { event_type: "debt_payment", category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    assert_equal "debt_payment", domain.heads.find_by!(financial_source_event: line.event).approved_version.event_type
    assert_empty @household.household_transactions
  end

  test "a person payment with unread direction can explicitly choose family support in the line form" do
    payment = source([ movement(nil, type: "unknown").merge(merchant: "Zelle to Lina Talun", limitations: [ "transaction_direction_unclear" ], source_amount_text: "15.00") ])
    link(payment)
    event = payment[:events].sole
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, payment[:revision], user: @user).context(event_ids: [ event.id ])
    assert presenter[:plan][:attention].sole[:recipient_question]
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    input = { lines: [ { event_id: event.id, decision: "edited", expected_head: line.expected_head,
      edit: { kind: "spending", money_direction: "out", amount_cents: 1500, category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    version = domain.heads.find_by!(financial_source_event: event).approved_version
    assert_equal "Family support", version.budget_category.name
    assert_equal "sent-to-someone:#{event.id}", version.external_reference
    assert_equal 1500, @household.household_transactions.sole.total_amount_cents
  end

  test "platform fees and cash withdrawals keep their existing spending questions" do
    %w[fee cash_withdrawal].each do |type|
      payment = source([ movement(-1500, type: type).merge(merchant: "Cash App #{type == 'fee' ? 'service fee' : 'ATM withdrawal'}") ])
      link(payment)
      event = payment[:events].sole
      refute FinancialDocuments::SourceReview::TransferPairs.person_wording?(event, FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event))
      line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
      refute_includes [ :person_payment, :person_payment_duplicate ], line.kind
    end
  end

  test "an older approved uncategorized person payment keeps its category question" do
    payment = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    identity = link(payment)
    event = payment[:events].sole
    approve(stage(event, identity: identity, amount: -3500, merchant: "Zelle to Lina Talun", category: nil))
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, payment[:revision], user: @user).context(event_ids: [ event.id ])[:plan][:attention].sole
    assert_equal :no_category, row[:kind]
    assert_equal false, row[:recipient_question]
    assert_empty @household.household_transactions
  end

  test "person payments require an answer and someone else is protected spending" do
    @household.budget_categories.create!(name: "family support", stack_key: "discretionary")
    payment = source([ movement(-3500, type: "transfer").merge(merchant: "Zelle Payment to Lina Talun") ])
    link(payment)
    evidence = payment[:events].sole.financial_source_evidence
    evidence.update!(payload: evidence.payload.merge("merchant" => "Lina Talun", "raw_description" => "Zelle to Lina Talun"))
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :person_payment, line.kind
    assert_empty FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).ready_ids
    input = { lines: [ { event_id: line.event.id, decision: "someone_else", expected_head: line.expected_head, shown: { event_type: "transfer", category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    actual = @household.household_transactions.sole
    assert_equal 3500, actual.total_amount_cents
    version = domain.heads.find_by!(financial_source_event: line.event).approved_version
    assert_equal "sent-to-someone:#{line.event.id}", version.external_reference
    assert_equal "family support", version.budget_category.name
    assert SpendingPatterns::Analyzer.protected_category?(version.budget_category.name)
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

  def source(rows, checksum: SecureRandom.hex(32), period: "2026-07", coverage: {}, extra_accounts: [])
    import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: checksum)
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    rows = rows.map { |row| row.merge(posted_on: period + "-07") } if period != "2026-07"
    amounts_known = rows.none? { |row| row[:signed_amount_cents].nil? }
    net = rows.sum { |row| row[:signed_amount_cents] } if amounts_known
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: "asset", period_start_on: period + "-01", period_end_on: Date.iso8601(period + "-01").end_of_month.iso8601, opening_balance_cents: 20_000, closing_balance_cents: net && 20_000 + net,
        printed_debit_cents: amounts_known ? rows.sum { |row| [ -row[:signed_amount_cents], 0 ].max } : nil, printed_credit_cents: amounts_known ? rows.sum { |row| [ row[:signed_amount_cents], 0 ].max } : nil, printed_row_count: rows.length } ] + extra_accounts, events: rows, reported_row_count: rows.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] }.merge(coverage))
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

  def stage(event, identity: @identity, amount: -1_000, purchase: :default, posted_on: "2026-07-07", event_type: "purchase", disposition: "include", overlap: "new", matched_version_id: nil, reason: "Participant reviewed the synthetic row", projection: { action: "none" }, merchant: "Synthetic merchant", category: @category)
    head = SourceReviewHead.find_by(household: @household, financial_source_event: event)
    purchase = amount&.abs if purchase == :default
    pending = head&.source_review_drafts&.pending&.first
    run_operation(OPS::DraftStage, { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, expected_pending_draft: pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest }, reason: reason, projection: projection,
      facts: { source_account_identity_version_id: identity.id, disposition: disposition, event_type: event_type, signed_amount_cents: amount, purchase_amount_cents: purchase, posted_on: posted_on,
        merchant: merchant, budget_category_id: category&.id, overlap_disposition: overlap, matched_version_id: matched_version_id } })
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
