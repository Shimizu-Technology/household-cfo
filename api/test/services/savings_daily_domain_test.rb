require "test_helper"
require_relative "../support/savings_daily_test_support"

class SavingsDailyDomainTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
  end

  teardown { travel_back }

  test "multiple exact purchases remain pending until approved without full setup or debt" do
    with_daily_operations do
      savings_enroll
      drafts = 3.times.map { daily_stage }
      assert_empty @savings_household.household_transactions
      assert_nil SavingsDailyLedger.find_by(savings_enrollment: @savings_enrollment)
      versions = drafts.map { |draft| daily_approve(draft).subject }
      assert_equal 3, versions.map(&:id).uniq.size
      assert_equal 7500, @savings_household.household_transactions.where(status: "confirmed").sum(:total_amount_cents)
      assert_equal 1, @savings_household.budget_years.count
      assert_equal 1, @savings_household.budget_years.sole.budget_periods.count
      assert_empty @savings_household.reload.confirmed_setup_fields
      assert_empty @savings_household.debts
      assert_equal "unknown", daily_projection[:spending_state]
      daily_check_in("spending")
      assert_equal 1, SavingsDailyCheckIn.where(savings_enrollment: @savings_enrollment).count
      assert_equal 7500, daily_projection[:reported_spend_cents]
      assert_nil savings_projection[:reported_cents]
    end
  end

  test "approved corrections append a canonical replacement preserve old positive facts and reject competing drafts" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      old_actual = original.household_transaction
      draft = daily_stage(3500, purchase: original.savings_daily_purchase)
      other = daily_stage(4500, purchase: original.savings_daily_purchase)
      assert_equal original.id, original.savings_daily_purchase.reload.current_version_id
      revised = daily_approve(draft).subject
      assert_equal "ignored", old_actual.reload.status
      assert_equal 2500, old_actual.total_amount_cents
      assert_equal original.purchased_on, old_actual.occurred_on
      assert_equal 3500, revised.household_transaction.total_amount_cents
      assert_equal 2, SavingsDailyPurchaseVersion.count
      assert_equal 1, @savings_household.household_transactions.where(status: "confirmed").count
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { daily_approve(other) }
      assert_equal 2, SavingsDailyPurchaseVersion.count
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsDailyPurchaseVersion.transaction(requires_new: true) { SavingsDailyPurchaseVersion.where(id: original.id).update_all(amount_cents: 1) }
      end
    end
  end

  test "reflection-only revision after midnight never changes financial date draft or actual" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
      purchase = draft.savings_daily_purchase
      first = daily_reflection(purchase).subject
      assert_empty @savings_household.household_transactions
      assert_equal "pending", draft.reload.status
      original = daily_approve(draft).subject
      actual_attributes = original.household_transaction.attributes
      head_attributes = purchase.reload.attributes
      travel_to Date.new(2026, 11, 2).in_time_zone("Pacific/Guam").beginning_of_day + 1.second
      second = daily_reflection(purchase, feeling_then: nil, feeling_now: "Different later feeling").subject
      assert_equal first.id, second.previous_version_id
      assert_equal actual_attributes, original.household_transaction.reload.attributes
      assert_equal head_attributes, purchase.reload.attributes
      assert_equal Date.new(2026, 11, 1), original.purchased_on
      assert_equal 1, SavingsDailyLedger.find_by(savings_enrollment: @savings_enrollment).sequence
      assert_equal 1, @savings_household.household_transactions.count
    end
  end

  test "optional reflection erasure clears every historical text without financial mutation even during hold and removed program membership" do
    with_daily_operations do
      savings_enroll
      financial = daily_approve(daily_stage).subject
      first = daily_reflection(financial.savings_daily_purchase, feeling_then: "Private earlier feeling").subject
      latest = daily_reflection(financial.savings_daily_purchase, feeling_now: "Private later feeling").subject
      actual = financial.household_transaction.attributes
      @savings_cohort.update!(savings_challenge_release_hold: true)
      @savings_membership.destroy!
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_reflection(financial.savings_daily_purchase) }
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_projection }
      daily_erase(latest)
      [ first, latest ].each do |version|
        assert_nil version.reload.feeling_then
        assert_nil version.feeling_now
        assert_equal "", version.reason
        assert version.erased_at
        assert_equal @savings_user.id, version.erased_by_user_id
      end
      assert_equal actual, financial.household_transaction.reload.attributes
      assert_equal 2, SavingsDailyReflectionVersion.count
      assert_equal 1, SavingsDailyPurchaseVersion.count
    end
  end

  test "missing and explicitly unknown reports do not become zero while no-spend conflicts require explained correction" do
    with_daily_operations do
      savings_enroll
      assert_nil daily_projection[:reported_spend_cents]
      daily_check_in("unknown")
      assert_nil daily_projection[:reported_spend_cents]
      no_spend = daily_check_in("no_spend")
      assert_equal 0, daily_projection[:reported_spend_cents]
      draft = daily_stage
      assert_raises(ArgumentError) { daily_approve(draft) }
      assert_empty @savings_household.household_transactions
      spend = daily_check_in("spending")
      assert_equal no_spend.id, spend.previous_version_id
      daily_approve(draft)
      assert_equal 2500, daily_projection[:reported_spend_cents]
      assert_raises(ArgumentError) { daily_check_in("no_spend") }
      assert_equal "no_spend", no_spend.reload.spending_state
    end
  end

  test "existing receipt canonical linking does not duplicate actuals and subsequent source-owned corrections fail closed" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      receipt = original.household_transaction
      assert_raises(ArgumentError) do
        daily_stage(2500, link_kind: "existing_transaction", linked_transaction_id: receipt.id,
          expected_canonical_digest: SavingsChallenge::Daily::CanonicalPurchase.digest(receipt))
      end
      assert_equal 1, @savings_household.household_transactions.count
      # Relinking the same personal head is permitted and adds no expense.
      draft = daily_stage(2500, purchase: original.savings_daily_purchase, link_kind: "existing_transaction", linked_transaction_id: receipt.id,
        expected_canonical_digest: SavingsChallenge::Daily::CanonicalPurchase.digest(receipt))
      linked = daily_approve(draft).subject
      assert_equal receipt.id, linked.household_transaction_id
      assert_equal 1, @savings_household.household_transactions.where(status: "confirmed").count
      assert_raises(ArgumentError) { daily_stage(2600, purchase: linked.savings_daily_purchase) }
    end
  end

  test "strict cents dates and unsupported client actor or evidence fields are rejected without drafts" do
    with_daily_operations do
      savings_enroll
      [ 1.5, "2500", -1, 0, 2_147_483_648 ].each { |amount| assert_raises(ArgumentError) { daily_stage(amount) } }
      assert_raises(ArgumentError) { daily_stage(2500, actor_id: @savings_user.id) }
      assert_raises(ArgumentError) { daily_stage(2500, evidence_supported_cents: 2500) }
      assert_raises(ArgumentError) { daily_stage(2500, purchased_on: "2026-02-30") }
      assert_raises(ArgumentError) { daily_stage(2500, purchased_on: "2026-10-31") }
      future = daily_stage(2500, on: Date.new(2026, 11, 2))
      assert_raises(ArgumentError) { daily_approve(future) }
      assert_raises(ArgumentError) { daily_check_in("no_spend", on: Date.new(2026, 11, 2)) }
      assert_empty @savings_household.household_transactions
    end
  end

  test "explicit manual void preserves positive canonical history and permits a separately accepted no-spend correction" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      daily_check_in("spending")
      draft = daily_stage(0, purchase: original.savings_daily_purchase, disposition: "void", splits: [])
      assert_equal "purchase", original.savings_daily_purchase.reload.current_version.disposition
      version = daily_approve(draft).subject
      assert_equal "void", version.disposition
      assert_equal 0, version.amount_cents
      assert_equal "ignored", original.household_transaction.reload.status
      assert_equal 2500, original.household_transaction.total_amount_cents
      assert_equal 1, @savings_household.household_transactions.count
      assert_nil daily_projection[:reported_spend_cents]
      daily_check_in("no_spend")
      assert_equal 0, daily_projection[:reported_spend_cents]
      assert_raises(ArgumentError) { daily_stage(0, disposition: "void", splits: []) }
      assert_raises(ArgumentError) { daily_stage(2500, purchase: version.savings_daily_purchase) }
    end
  end

  test "an independently changed canonical purchase fails closed before drafting and in daily projections" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      original.household_transaction.update!(merchant: "Changed through the canonical workflow")
      assert_raises(ArgumentError) { daily_stage(3000, purchase: original.savings_daily_purchase) }
      assert_nil daily_projection[:reported_spend_cents]
      assert daily_projection[:canonical_links_changed]
      assert_equal 1, SavingsDailyPurchaseDraft.count
    end
  end

  test "a source-owned actual cannot be voided even if originally recorded through the manual daily path" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      revision = FinancialExtractionRevision.create!(household: @savings_household, revision_number: 1, contract_version: "source_accounting_v1",
        source_document_identity: "synthetic-#{SecureRandom.hex(8)}", payload_digest: SecureRandom.hex(32))
      account = FinancialSourceAccount.create!(household: @savings_household, financial_extraction_revision: revision, source_key: "synthetic", account_basis: "asset")
      event = FinancialSourceEvent.create!(household: @savings_household, financial_extraction_revision: revision, financial_source_account: account,
        row_identity: SecureRandom.hex(32), row_kind: "posted", event_type: "purchase", position: 0, signed_amount_cents: -2500,
        expense_amount_cents: 2500, posted_on: original.purchased_on)
      original.household_transaction.update!(financial_source_event: event)
      assert_raises(ArgumentError) { daily_stage(0, purchase: original.savings_daily_purchase, disposition: "void", splits: []) }
      assert_equal "confirmed", original.household_transaction.reload.status
      assert_equal original.id, original.savings_daily_purchase.reload.current_version_id
      assert_equal 1, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
    end
  end

  test "source linking uses reviewed authorization dates and never trusts the unapproved raw extracted date" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 3).in_time_zone("Pacific/Guam").noon
      import = FinancialDocumentImport.create!(household: @savings_household, uploaded_by_user: @savings_user, document_kind: "statement", status: "needs_review",
        filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
      attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
      normalized = FinancialDocuments::AccountingContract.normalize({ contract_version: "source_accounting_v1",
        accounts: [ { account_key: "synthetic", account_basis: "asset", period_start_on: "2026-11-01", period_end_on: "2026-11-03",
          opening_balance_cents: 300_000, closing_balance_cents: 297_500, printed_debit_cents: 2500, printed_credit_cents: 0, printed_row_count: 1 } ],
        events: [ { account_key: "synthetic", row_kind: "posted", event_type: "purchase", signed_amount_cents: -2500, posted_on: "2026-11-03",
          authorized_on: "2026-11-01", merchant: "Synthetic Cafe", locator: { page: 1, row: 1 } } ], reported_row_count: 1 },
        coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
      source = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: normalized).call
      account = source[:revision].financial_source_accounts.sole
      runner = HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user)
      identity = runner.run(operation_key: "source_review.account.link", idempotency_key: SecureRandom.uuid,
        input: { source_account_id: account.id, tracked_account_id: nil, account_basis: "asset", label: "Synthetic source", base_version_id: nil, base_lock_version: 0,
          statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Reviewed synthetic identity" }).subject
      event = source[:events].sole
      draft = runner.run(operation_key: "source_review.draft.stage", idempotency_key: SecureRandom.uuid,
        input: { event_id: event.id, base_version_id: nil, base_lock_version: 0, reason: "Corrected authorization date from reviewed source",
          projection: { action: "create" }, facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase",
            signed_amount_cents: -2500, purchase_amount_cents: 2500, posted_on: "2026-11-03", authorized_on: "2026-11-02",
            merchant: "Synthetic Cafe", budget_category_id: @daily_category.id, overlap_disposition: "distinct" } }).subject
      approved = runner.run(operation_key: "source_review.draft.approve", idempotency_key: SecureRandom.uuid,
        input: { draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest }).subject
      transaction = approved.source_projection_revision.replacement_transaction
      link = { link_kind: "existing_transaction", linked_transaction_id: transaction.id,
        expected_canonical_digest: SavingsChallenge::Daily::CanonicalPurchase.digest(transaction) }
      assert_raises(ArgumentError) { daily_stage(2500, on: Date.new(2026, 11, 1), **link) }
      daily = daily_approve(daily_stage(2500, on: Date.new(2026, 11, 2), **link)).subject
      assert_equal Date.new(2026, 11, 2), daily.purchased_on
      assert_equal Date.new(2026, 11, 3), daily.posted_on
      assert_equal Date.new(2026, 11, 1), event.reload.authorized_on
      assert_equal 1, @savings_household.household_transactions.count
      assert_raises(ArgumentError) { daily_stage(0, purchase: daily.savings_daily_purchase, on: daily.purchased_on, disposition: "void", splits: []) }
    end
  end

  test "private pagination reauthorizes every call and never grants household partners another participant's records" do
    with_daily_operations do
      savings_enroll
      3.times { daily_approve(daily_stage) }
      reader = SavingsChallenge::Daily::ParticipantReader.new(@savings_enrollment, user: @savings_user)
      page = reader.page(:purchase_versions, limit: 2)
      assert_equal 2, page[:records].size
      next_page = reader.page(:purchase_versions, limit: 2, after_id: page[:next_cursor])
      assert_equal 1, next_page[:records].size
      assert_nil next_page[:next_cursor]
      assert_empty page[:records].map(&:id) & next_page[:records].map(&:id)
      assert_raises(ArgumentError) { reader.page(:purchase_versions, limit: 101) }
      assert_raises(ArgumentError) { reader.page(:purchase_versions, after_id: 1.5) }
      partner = User.create!(clerk_id: "daily_partner_#{SecureRandom.hex(8)}", email: "daily-partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { SavingsChallenge::Daily::ParticipantReader.new(@savings_enrollment, user: partner).page(:purchase_versions) }
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { reader.find(:purchases, id: page[:records].first.savings_daily_purchase_id) }
    end
  end

  test "private approval replay reauthorizes release and actor while erase replay survives a program hold" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
      first = daily_approve(draft, token: "daily approval replay")
      replay = daily_approve(draft, token: "daily approval replay")
      assert replay.replayed?
      assert_equal first.subject.id, replay.subject.id
      assert_equal 1, @savings_household.household_transactions.count
      reflection = daily_reflection(first.subject.savings_daily_purchase).subject
      old_lock = reflection.savings_daily_reflection.reload.lock_version
      daily_erase(reflection, token: "erase replay", head_lock: old_lock)
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_approve(draft, token: "daily approval replay") }
      assert daily_erase(reflection, token: "erase replay", head_lock: old_lock).replayed?
    end
  end

  test "private operation audit and execution mirrors never retain amounts dates merchants feelings or raw idempotency keys" do
    with_daily_operations do
      savings_enroll
      financial = daily_approve(daily_stage).subject
      response = daily_reflection(financial.savings_daily_purchase, feeling_then: "secret sentiment", token: "sensitive sentiment key")
      execution = response.execution
      assert_empty execution.normalized_input
      assert_empty execution.before_snapshot
      assert_empty execution.after_snapshot
      encoded = [ execution.attributes, execution.household_audit_event.attributes ].to_json
      %w[secret sentiment sensitive Synthetic].each { |word| refute_includes encoded, word }
      assert_match(/\Aprivate:/, execution.idempotency_key)
    end
  end

  test "private daily request facts and reflections are filtered from logs and model inspection" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    input = { "feeling_then" => "Private then", "feeling_now" => "Private now", "amount_cents" => 2500, "merchant" => "Private merchant",
      "purchased_on" => "2026-11-01", "local_on" => "2026-11-01", "splits" => [], "spending_state" => "spending", "snapshot" => { "reported_cents" => 50000 } }
    assert filter.filter(input).values.all? { |value| value == "[FILTERED]" }
  end

  test "a role changed after enrollment denies private reads and writes despite retained household and cohort membership" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      @savings_user.update!(role: "coach")
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_projection }
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_stage }
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_reflection(original.savings_daily_purchase) }
      assert_equal 1, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 1, @savings_household.household_transactions.count
    end
  end

  test "privacy erasure never crosses participant or household boundaries even for writable partners" do
    with_daily_operations do
      savings_enroll
      purchase = daily_approve(daily_stage).subject.savings_daily_purchase
      reflection = daily_reflection(purchase).subject
      head = reflection.savings_daily_reflection.reload
      input = { reflection_id: head.id, erase_accepted: true, expected_version_id: head.current_version_id, expected_head_lock_version: head.lock_version }
      partner = User.create!(clerk_id: "erase_partner_#{SecureRandom.hex(8)}", email: "erase-partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
      savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: false,
        expected_acceptance_digest: savings_offer_digest(user: partner) }, user: partner)
      assert_raises(ActiveRecord::RecordNotFound) { savings_run("daily.reflection.erase", input, user: partner) }
      foreign = Household.create!(created_by_user: partner, name: "Other synthetic household")
      foreign.household_memberships.create!(user: @savings_user, role: "partner")
      assert_raises(ActiveRecord::RecordNotFound) { savings_run("daily.reflection.erase", input, household: foreign) }
      assert_equal "Hopeful", reflection.reload.feeling_then
      assert_nil reflection.erased_at
    end
  end

  private

  def daily_projection
    SavingsChallenge::Daily::DayProjection.new(@savings_enrollment.reload, user: @savings_user, local_on: @savings_enrollment.starts_on).call
  end
end
