require "test_helper"
require_relative "../support/savings_challenge_test_support"

class SavingsChallengeFoundationTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
  end
  teardown { travel_back }

  test "early and late enrollment clocks are personal frozen inclusive ninety days without financial setup" do
    with_savings_runtime do
      travel_to Time.find_zone!("Pacific/Guam").local(2026, 10, 20, 12)
      savings_enroll(late: false)
      assert_equal Date.new(2026, 11, 1), @savings_enrollment.starts_on
      assert_equal Date.new(2027, 1, 29), @savings_enrollment.ends_on
      calendar = SavingsChallenge::ParticipantSerializer.calendar(@savings_enrollment)
      assert_equal "upcoming", calendar[:phase]
      assert_nil calendar[:day]
      assert_equal "2026-11-30", calendar[:checkpoints][30]
      assert_equal "2026-12-30", calendar[:checkpoints][60]
      assert_equal "2027-01-29", calendar[:checkpoints][90]
      assert_nil savings_projection[:reported_cents]
      assert_equal 50_000, savings_plan.target_cents
      assert_equal 0, @savings_household.budget_years.count
      assert_equal 0, @savings_household.debts.count
      assert_nil @savings_enrollment.reload.current_accepted_plan_version.previous_version_id
    end
  end

  test "late start requires explicit acceptance and cohort capacity remains bounded" do
    with_savings_runtime do
      assert_raises(ArgumentError) { savings_enroll(late: false) }
      assert_equal 0, SavingsEnrollment.where(cohort: @savings_cohort).count
      savings_enroll
      assert_equal Date.new(2026, 11, 15), @savings_enrollment.starts_on
      assert_equal Date.new(2027, 2, 12), @savings_enrollment.ends_on
      assert @savings_enrollment.late_start_accepted?
      assert_equal "2026-12-14", SavingsChallenge::ParticipantSerializer.calendar(@savings_enrollment)[:checkpoints][30]
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { savings_enroll }
      assert_equal 1, SavingsEnrollment.where(cohort: @savings_cohort).count
    end
  end

  test "new endpoint operations fail closed without a sealed version three savings release and ordinary cohorts cannot join" do
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_enroll }
    with_savings_runtime do
      @savings_cohort.update!(savings_challenge_enabled: false)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_enroll }
      @savings_cohort.update!(savings_challenge_enabled: true, savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_enroll }
    end
    assert_equal 0, SavingsEnrollment.count
  end

  test "plan revisions preserve earlier target versions and postpone uses nil rather than zero" do
    with_savings_runtime do
      savings_enroll
      first = savings_plan
      first_seq = @savings_enrollment.reload.approval_sequence
      custom = savings_plan(30_000)
      assert_equal first.id, custom.previous_version_id
      assert_equal 50_000, savings_projection(approval_sequence: first_seq)[:target_cents]
      assert_equal 30_000, savings_projection[:target_cents]
      postponed = savings_plan(nil)
      assert_nil postponed.target_cents
      assert_nil savings_projection[:target_cents]
      assert_nil savings_projection[:progress_basis_points]
      assert_raises(ArgumentError) { savings_plan(0) }
      assert_raises(ArgumentError) { savings_plan(50_000.0) }
      assert_equal 50_000, first.reload.target_cents
    end
  end

  test "contributions remain pending until approved and correction drafts preserve prior approved progress" do
    with_savings_runtime do
      savings_enroll
      savings_plan
      draft = savings_draft(10_000)
      assert_nil savings_projection[:reported_cents]
      first = savings_approve(draft)
      initial_seq = @savings_enrollment.reload.approval_sequence
      assert_equal 10_000, savings_projection[:reported_cents]
      correction = savings_draft(9_000, entry: first.savings_entry)
      assert_equal 10_000, savings_projection[:reported_cents]
      corrected = savings_approve(correction)
      assert_equal first.id, corrected.previous_version_id
      assert_equal first.savings_entry_id, corrected.savings_entry_id
      assert_equal 2, corrected.version_number
      assert_equal 9_000, savings_projection[:reported_cents]
      assert_equal 10_000, savings_projection(approval_sequence: initial_seq)[:reported_cents]
      assert_equal 0, corrected.evidence_supported_cents
      assert_equal 10_000, first.reload.signed_cents
    end
  end

  test "actual withdrawals are distinct and signed negative net remains visible after the window" do
    with_savings_runtime do
      savings_enroll
      savings_plan
      savings_approve(savings_draft(10_000))
      savings_approve(savings_draft(-15_000, funding: "withdrawal"))
      assert_equal(-5_000, savings_projection[:reported_cents])
      assert_equal 0, savings_projection[:progress_basis_points]
      assert_equal 0, savings_projection[:evidence_supported_cents]
      travel_to Time.find_zone!("Pacific/Guam").local(2027, 2, 13, 12)
      assert_equal(-5_000, savings_projection[:reported_cents], "missing final attestation does not erase approved progress")
      assert_equal "window_ended", SavingsChallenge::ParticipantSerializer.calendar(@savings_enrollment)[:phase]
    end
  end

  test "approval sequence replay selects financial heads before cutoff without resurrecting a moved correction" do
    with_savings_runtime do
      travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
      savings_enroll
      travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
      prior = savings_approve(savings_draft(100, on: Date.new(2026, 11, 1)))
      pending = savings_draft(200, entry: prior.savings_entry, on: Date.new(2026, 11, 15))
      assert_equal 100, savings_projection(cutoff_on: Date.new(2026, 11, 1))[:reported_cents]
      savings_approve(pending)
      assert_nil savings_projection(cutoff_on: Date.new(2026, 11, 1))[:reported_cents]
      assert_equal 100, savings_projection(cutoff_on: Date.new(2026, 11, 1), approval_sequence: prior.approval_sequence)[:reported_cents]
      assert_equal 200, savings_projection[:reported_cents]
      savings_zero(on: Date.new(2026, 11, 1))
      assert_equal 0, savings_projection(cutoff_on: Date.new(2026, 11, 1))[:reported_cents]
      assert_nil savings_projection(cutoff_on: Date.new(2026, 11, 2))[:reported_cents]
    end
  end

  test "future promises can be drafted but never become automatically approved actuals" do
    with_savings_runtime do
      savings_enroll
      future = savings_draft(10_000, on: @savings_enrollment.starts_on + 1)
      assert_raises(ArgumentError) { savings_approve(future) }
      assert_nil savings_projection[:reported_cents]
      travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 16, 12)
      assert_nil savings_projection[:reported_cents]
      assert_equal "pending", future.reload.status
      savings_approve(future)
      assert_equal 10_000, savings_projection[:reported_cents]
      assert_raises(ArgumentError) { savings_draft(100, on: @savings_enrollment.starts_on - 1) }
      assert_raises(ArgumentError) { savings_draft(100, on: @savings_enrollment.ends_on + 1) }
    end
  end

  test "unknown zero attestation and excluded funding remain separate with immutable cutoff history" do
    with_savings_runtime do
      savings_enroll
      assert_nil savings_projection[:reported_cents]
      first = savings_zero
      assert_equal 0, savings_projection[:reported_cents]
      again = savings_zero
      assert_equal first.id, again.previous_attestation_id
      savings_approve(savings_draft(50_000, funding: "borrowed"))
      assert_equal 0, savings_projection[:reported_cents]
      travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 16, 12)
      assert_nil savings_projection[:reported_cents], "yesterday's attestation cannot attest today"
      savings_approve(savings_draft(100))
      assert_equal 100, savings_projection[:reported_cents]
      assert_raises(ArgumentError) { savings_zero }
    end
  end

  test "exact target cents and nil target flow through persisted approved versions" do
    with_savings_runtime do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(49_999)).savings_entry
      assert_equal false, savings_projection[:achieved]
      [ 50_000, 50_001 ].each do |cents|
        savings_approve(savings_draft(cents, entry: entry))
        assert_equal true, savings_projection[:achieved]
        assert_equal cents, savings_projection[:reported_cents]
      end
      savings_plan(nil)
      assert_nil savings_projection[:achieved]
      assert_nil savings_projection[:progress_basis_points]
    end
  end

  test "conflicting corrections reject stale entry version and lock while keeping immutable history" do
    with_savings_runtime do
      savings_enroll
      first = savings_approve(savings_draft(10_000))
      a = savings_draft(9_000, entry: first.savings_entry)
      b = savings_draft(8_000, entry: first.savings_entry)
      savings_approve(a)
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { savings_approve(b) }
      assert_equal 9_000, savings_projection[:reported_cents]
      assert_equal "pending", b.reload.status
      assert_equal 2, first.savings_entry.savings_entry_versions.count
    end
  end

  test "redacted executions replay the same private version and reject different inputs" do
    with_savings_runtime do
      token = "private cents 12345 date 2026-11-15"
      savings_enroll
      draft = savings_draft(12_345)
      version = savings_approve(draft, token: token)
      replay = savings_approve(draft, token: token)
      assert_equal version.id, replay.id
      assert_equal 1, version.savings_entry.savings_entry_versions.count
      execution = @savings_household.household_operation_executions.order(:id).last
      %w[normalized_input before_snapshot predicted_after_snapshot after_snapshot].each { |key| assert_equal({}, execution.public_send(key)) }
      audit = execution.household_audit_event
      serialized = JSON.generate(execution.attributes) + JSON.generate(audit.metadata)
      refute_includes serialized, token
      refute_includes JSON.generate(audit.metadata), "2026-11-15"
      refute_includes JSON.generate(audit.metadata), "new_money_reserved"
      assert_match(/\Aprivate:[a-f0-9]{64}\z/, execution.idempotency_key)
      assert_raises(HouseholdFinance::Operations::Runner::IdempotencyConflict) do
        savings_run("entry.approve", { draft_id: draft.id, accepted: false, expected_draft_lock_version: 0, expected_version_id: nil, expected_entry_lock_version: 0 }, token: token)
      end
    end
  end

  test "run_prepared uses injected actor and redacted replays recheck membership hold and invitation" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      operation = HouseholdFinance::Operations::Savings::EntryApprove.new(@savings_household, user: @savings_user)
      prepared = operation.prepare(cohort_id: @savings_cohort.id, draft_id: draft.id, accepted: true,
        expected_draft_lock_version: 0, expected_version_id: nil, expected_entry_lock_version: 0)
      runner = HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user)
      run = -> { runner.run_prepared(prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint, idempotency_key: "prepared-savings", source: "mia") }
      assert_not run.call.replayed?
      assert run.call.replayed?
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { run.call }
      @savings_cohort.update!(savings_challenge_release_hold: false)
      @savings_membership.destroy!
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { run.call }
      CohortMembership.create!(cohort: @savings_cohort, user: @savings_user, role: "participant")
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable, "new membership cannot silently revive old enrollment") { run.call }
    end
  end

  test "household partners staff and foreign participants cannot approve or replay another participant's reservation" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      partner = User.create!(clerk_id: "clerk_partner_#{SecureRandom.hex(4)}", email: "partner-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      CohortMembership.create!(cohort: @savings_cohort, user: partner, role: "participant")
      input = { draft_id: draft.id, accepted: true, expected_draft_lock_version: 0, expected_version_id: nil, expected_entry_lock_version: 0 }
      assert_raises(ActiveRecord::RecordNotFound) { savings_run("entry.approve", input, user: partner) }
      assert_equal "pending", draft.reload.status
      @savings_household.household_memberships.find_by!(user: @savings_user).update!(role: "coach_viewer")
      assert_raises(HouseholdFinance::Operations::Runner::InvalidPreparedOperation) { savings_approve(draft) }
    end
  end

  test "untrusted actor evidence currency head and malformed money fields never persist financial approvals" do
    with_savings_runtime do
      savings_enroll
      base = { signed_cents: 100, effective_on: "2026-11-15", funding_source: "new_money_reserved", expected_version_id: nil }
      [ { actor_id: @savings_user.id }, { evidence_supported_cents: 100 }, { currency: "EUR" }, { current_head: true }, { signed_cents: 1.5 }, { signed_cents: "100" }, { effective_on: "2026-02-30" } ].each do |change|
        assert_raises(ArgumentError) { savings_run("entry.stage", base.merge(change)) }
      end
      assert_equal 0, SavingsEntryVersion.count
      assert_equal 0, SavingsEntry.count
    end
  end
end
