require "test_helper"
require_relative "../support/savings_debt_test_support"

class SavingsHouseholdDebtLinkTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "an older client cannot silently unlink an approved household identity" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      card = first.savings_debt_card.reload
      assert_no_difference [ "SavingsDebtDraft.count", "SavingsDebtVersion.count", "HouseholdOperationExecution.count" ] do
        error = assert_raises(ArgumentError) do
          savings_run("debt.stage", { card_id: card.id, terms: debt_terms(balance_cents: 40_000),
            expected_version_id: first.id, expected_head_lock_version: card.lock_version,
            reason: "Manual correction from an older client", source_mapping: nil })
        end
        assert_includes error.message, "Refresh the app"
      end
      assert_equal debt.id, card.reload.household_debt_id
      assert_equal first.id, card.current_version_id
      assert_equal first.household_debt_snapshot, first.reload.household_debt_snapshot
    end
  end

  test "link approval preserves exact unknown and zero values without modifying household debt budget or savings" do
    with_savings_runtime do
      savings_enroll
      debt = household_card(balance_known: false, minimum_payment_cents: 0, minimum_payment_known: true)
      before = debt.attributes
      candidate = household_candidate(debt)
      assert_nil candidate.dig(:proposed_terms, :balance_cents)
      assert_equal 0, candidate.dig(:proposed_terms, :minimum_payment_cents)
      draft = linked_stage(debt_terms(balance_cents: nil, minimum_payment_cents: 0), debt: debt)
      assert_nil draft.savings_debt_card.household_debt_id
      version = debt_approve(draft)
      assert_equal debt.id, version.savings_debt_card.reload.household_debt_id
      assert_equal candidate[:snapshot], version.household_debt_snapshot
      assert_equal candidate[:fingerprint], version.household_debt_fingerprint
      assert_nil version.terms["balance_cents"]
      assert_equal 0, version.terms["minimum_payment_cents"]
      assert_equal before, debt.reload.attributes
      assert_equal 0, @savings_household.budget_years.count
      assert_equal 0, SavingsEntryVersion.where(savings_enrollment: @savings_enrollment).count
      refute debt_read[:cards].sole[:household_terms_changed]
      assert_raises(ActiveRecord::RecordNotSaved) { version.update!(household_debt_snapshot: {}) }
    end
  end

  test "stale saved card changes fail approval atomically and later approval flags divergence without rewriting history" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      pending = linked_stage(debt_terms, debt: debt)
      debt.update!(balance_cents: 45_000)
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { debt_approve(pending) }
      assert_equal "pending", pending.reload.status
      assert_nil pending.savings_debt_card.reload.current_version_id
      assert_equal 0, pending.savings_debt_card.savings_debt_versions.count
      first = debt_approve(linked_stage(debt_terms(balance_cents: 45_000), debt: debt))
      debt.update!(balance_cents: 50_000)
      assert debt_read[:cards].sole[:household_terms_changed]
      assert_equal 45_000, first.reload.terms["balance_cents"]
      assert_equal 45_000, first.household_debt_snapshot["balance_cents"]
      correction = linked_stage(debt_terms(balance_cents: 50_000), debt: debt, card: first.savings_debt_card)
      assert_equal first.id, first.savings_debt_card.reload.current_version_id
      second = debt_approve(correction)
      assert_equal first.id, second.previous_version_id
      assert_equal 50_000, second.terms["balance_cents"]
      refute debt_read[:cards].sole[:household_terms_changed]
      assert_equal 50_000, debt.reload.balance_cents
    end
  end

  test "foreign loan archived and forged mappings cannot be linked or persisted" do
    with_savings_runtime do
      savings_enroll
      card = household_card
      foreign = household_card(household: Household.create!(name: "Other fictional household", created_by_user: @savings_owner))
      loan = household_card(label: "Fictional loan", debt_type: "auto_loan")
      archived = household_card(label: "Fictional archived card", active: false, archived_at: Time.current)
      assert_raises(ActiveRecord::RecordNotFound) { linked_stage(debt_terms, debt: foreign) }
      [ loan, archived ].each { |debt| assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { linked_stage(debt_terms, debt: debt, fingerprint: "a" * 64) } }
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { linked_stage(debt_terms, debt: card, fingerprint: "0" * 64) }
      assert_equal 0, SavingsDebtDraft.count
      draft = linked_stage(debt_terms, debt: card)
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsDebtDraft.transaction(requires_new: true) { draft.update_columns(household_debt_id: foreign.id) }
      end
      assert_equal card.id, draft.reload.household_debt_id
    end
  end

  test "one saved card links once per enrollment and an approved link cannot be assigned independently of reviewed terms" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      duplicate = linked_stage(debt_terms, debt: debt)
      assert_raises(ArgumentError) { debt_approve(duplicate) }
      assert_nil duplicate.savings_debt_card.reload.current_version_id
      assert_equal 1, SavingsDebtVersion.count
      other = household_card(label: "Other household card")
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsDebtCard.transaction(requires_new: true) { first.savings_debt_card.update_columns(household_debt_id: other.id) }
      end
      assert_equal debt.id, first.savings_debt_card.reload.household_debt_id
    end
  end

  test "manual correction deliberately removes current link while preserving approved prior link snapshot" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      card = first.savings_debt_card.reload
      pending = savings_run("debt.stage", { card_id: card.id, terms: debt_terms(balance_cents: nil),
        source_mapping: nil, household_debt_mapping: nil, expected_version_id: first.id,
        expected_head_lock_version: card.lock_version, reason: "Explicitly unlink this correction" }).subject
      second = debt_approve(pending)
      assert_nil second.savings_debt_card.reload.household_debt_id
      assert_nil second.household_debt_id
      assert_equal debt.id, first.reload.household_debt_id
      assert_equal debt.id, first.household_debt_snapshot["id"]
      assert_equal 30_000, debt.reload.balance_cents
    end
  end

  test "request replay retains original linked version and hold blocks recovery without leaking facts into generic audits" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      draft = linked_stage(debt_terms, debt: debt)
      first = debt_approve(draft, token: "private link recovery")
      assert_equal first.id, debt_approve(draft, token: "private link recovery").id
      execution = @savings_household.household_operation_executions.where(operation_key: "savings.debt.approve").sole
      assert_equal({}, execution.normalized_input)
      refute_includes execution.household_audit_event.metadata.to_json, debt.label
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { debt_approve(draft, token: "private link recovery") }
    end
  end

  test "shared household card can be deliberately reviewed in separate participant enrollments without exposing private linked identities" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      first_enrollment = @savings_enrollment
      partner = User.create!(clerk_id: "fictional_linked_card_partner", email: "linked-card-partner@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
      @savings_user = partner
      savings_enroll
      candidates = SavingsChallenge::Debt::Reader.new(@savings_enrollment, user: partner).household_candidates
      assert_nil candidates.fetch(:records).sole[:linked_card_id]
      second = debt_approve(linked_stage(debt_terms(balance_cents: 25_000), debt: debt))
      assert_not_equal first_enrollment.id, second.savings_enrollment_id
      assert_equal debt.id, second.household_debt_id
      assert_equal [ second.savings_debt_card_id ], debt_read[:cards].map { |row| row[:card_id] }
      assert_equal 30_000, first.reload.terms["balance_cents"]
      assert_equal 30_000, debt.reload.balance_cents
    end
  end

  test "parent household moves fail for pending current and historical review references" do
    with_savings_runtime do
      savings_enroll
      other = Household.create!(created_by_user: @savings_owner, name: "Other synthetic household")
      pending_debt = household_card(label: "Pending saved card")
      linked_stage(debt_terms, debt: pending_debt)
      assert_parent_household_move_blocked(pending_debt, other)
      current_debt = household_card(label: "Current saved card")
      first = debt_approve(linked_stage(debt_terms, debt: current_debt))
      assert_parent_household_move_blocked(current_debt, other)
      unlink = unlink_stage(first.savings_debt_card.reload)
      debt_approve(unlink)
      assert_nil first.savings_debt_card.reload.household_debt_id
      assert_parent_household_move_blocked(current_debt, other)
      assert_equal @savings_household.id, current_debt.reload.household_id
      assert_equal current_debt.id, first.reload.household_debt_snapshot["id"]
    end
  end

  test "kind corrections mark current optional terms changed without rewriting the dated approval" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      reviewed = first.household_debt_snapshot.deep_dup
      debt.update!(debt_type: "auto_loan", balance_cents: 40_000)
      assert_equal "auto_loan", debt.reload.debt_type
      assert_equal first.id, first.savings_debt_card.reload.current_version_id
      assert_equal reviewed, first.reload.household_debt_snapshot
      assert_equal "credit_card", reviewed["debt_type"]
      assert_equal false, SavingsChallenge::Debt::HouseholdMapping.new(@savings_household).current?(first)
      assert debt_read[:cards].sole[:household_terms_changed]
      assert_equal 30_000, debt_read[:cards].sole[:terms]["balance_cents"]
      assert_equal [], SavingsChallenge::Debt::Reader.new(@savings_enrollment, user: @savings_user).household_candidates[:records]
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { linked_stage(debt_terms, debt: debt, card: first.savings_debt_card, fingerprint: first.household_debt_fingerprint) }
    end
  end

  test "kind corrections with pending links reject later approval safely and explicit unlink permits ordinary edits" do
    with_savings_runtime do
      savings_enroll
      debt = household_card
      pending = linked_stage(debt_terms, debt: debt)
      debt.update!(debt_type: "personal_loan")
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { debt_approve(pending) }
      assert_equal "pending", pending.reload.status
      assert_nil pending.savings_debt_card.reload.current_version_id
      debt.update!(debt_type: "credit_card")
      first = debt_approve(linked_stage(debt_terms, debt: debt))
      second = debt_approve(unlink_stage(first.savings_debt_card.reload))
      debt.update!(debt_type: "auto_loan", balance_cents: 45_000)
      assert_nil second.savings_debt_card.reload.household_debt_id
      assert_equal "auto_loan", debt.reload.debt_type
      assert_equal 45_000, debt.balance_cents
      assert_equal "credit_card", first.reload.household_debt_snapshot["debt_type"]
      unrelated = household_card(label: "Unlinked saved debt")
      unrelated.update!(debt_type: "other", balance_cents: 50_000)
      assert_equal "other", unrelated.reload.debt_type
      other = Household.create!(created_by_user: @savings_owner, name: "Unlinked transfer destination")
      unrelated.update!(household: other)
      assert_equal other.id, unrelated.reload.household_id
    end
  end

  private

  def assert_parent_household_move_blocked(debt, other)
    error = assert_raises(ActiveRecord::RecordInvalid) { debt.update!(household: other) }
    assert_includes error.message, "optional card review history belongs to this household"
    debt.reload
    assert_raises(ActiveRecord::StatementInvalid) do
      Debt.transaction(requires_new: true) { debt.update_columns(household_id: other.id) }
    end
    assert_equal @savings_household.id, debt.reload.household_id
  end

  def unlink_stage(card)
    savings_run("debt.stage", { card_id: card.id, terms: debt_terms, source_mapping: nil, household_debt_mapping: nil,
      expected_version_id: card.current_version_id, expected_head_lock_version: card.lock_version, reason: "Deliberately unlink dated terms" }).subject
  end

  def household_card(**attributes)
    Debt.create!({ household: @savings_household, label: "Fictional saved card", debt_type: "credit_card", balance_cents: 30_000, minimum_payment_cents: 0, source_type: "manual_ui" }.merge(attributes))
  end

  def household_candidate(debt)
    SavingsChallenge::Debt::HouseholdMapping.new(debt.household).candidate(debt)
  end

  def linked_stage(terms, debt:, card: nil, fingerprint: nil)
    card&.reload
    savings_run("debt.stage", { terms: terms, card_id: card&.id, expected_version_id: card&.current_version_id, expected_head_lock_version: card&.lock_version || 0,
      reason: card&.current_version_id ? "Reviewed current household terms" : "", household_debt_mapping: { household_debt_id: debt.id, fingerprint: fingerprint || household_candidate(debt).fetch(:fingerprint) } }).subject
  end
end
