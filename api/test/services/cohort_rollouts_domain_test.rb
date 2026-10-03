# frozen_string_literal: true

require "test_helper"

class CohortRolloutsDomainTest < ActiveSupport::TestCase
  setup do
    @owner = create_user(role: "admin", first_name: "Release", last_name: "Owner")
    @cohort = Cohort.create!(
      name: "Rollout domain #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: @owner
    )
    @first = create_user(first_name: "First", last_name: "Household")
    @second = create_user(first_name: "Second", last_name: "Household")
    @cohort.cohort_memberships.create!(user: @first, role: "participant")
    @cohort.cohort_memberships.create!(user: @second, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: @cohort.id)).call
    @release = @cohort.cohort_releases.sole
    @machine = CohortRollouts::StateMachine.new(
      cohort: @cohort,
      actor: @owner,
      actor_role_snapshot: "platform_admin"
    )
  end

  test "readiness is privacy safe and applies removed revoked accepted awaiting precedence" do
    pending = create_user(invitation_status: "pending")
    revoked = create_user(invitation_status: "revoked")
    @cohort.cohort_memberships.create!(user: pending, role: "participant")
    revoked_membership = @cohort.cohort_memberships.create!(user: revoked, role: "participant")

    snapshot = CohortRollouts::Contract.readiness_snapshot(cohort: @cohort)
    states = snapshot.fetch("participants").index_by { |entry| entry.fetch("user_id") }

    assert_equal "ready", states.fetch(@first.id).fetch("state")
    assert_equal "awaiting_acceptance", states.fetch(pending.id).fetch("state")
    assert_equal "revoked", states.fetch(revoked.id).fetch("state")
    refute_includes snapshot.to_json, "@example.com"

    revoked_membership.destroy!
    assert_equal "removed", CohortRollouts::Contract.readiness_state(cohort: @cohort, user: revoked)
  end

  test "plans the exact current roster as immutable ordered waves without changing runtime" do
    result = plan!(waves: [
      { name: "First households", user_ids: [ @first.id ] },
      { name: "Second households", user_ids: [ @second.id ] }
    ])
    rollout = result.rollout

    assert_equal "planned", rollout.status
    assert_equal 0, rollout.current_wave_position
    assert_equal [ 1, 2 ], rollout.waves.pluck(:position)
    assert_equal [ @first.id, @second.id ], rollout.participants.order(:user_id).pluck(:user_id)
    assert_equal "planned", result.transition.event_type
    assert_equal false, result.transition.participant_runtime_changed
    assert_equal false, result.after_snapshot.fetch("participant_runtime_changed")
    assert_equal @release.id, result.before_snapshot.fetch("latest_release_id")
    assert_equal CohortRollouts::Contract.roster_digest(@cohort),
      result.before_snapshot.fetch("participant_roster_digest")
    refute_includes result.before_snapshot.to_json, "@example.com"
  end

  test "rejects stale or inexact plan evidence" do
    waves = [ { name: "Everyone", user_ids: [ @first.id, @second.id ] } ]

    assert_raises(CohortRollouts::StateMachine::Stale) do
      @machine.plan!(plan_input(waves: waves).merge(expected_roster_digest: "0" * 64))
    end
    error = assert_raises(CohortRollouts::StateMachine::Ineligible) do
      @machine.plan!(plan_input(waves: [ { name: "Missing household", user_ids: [ @first.id ] } ]))
    end
    assert_includes error.blockers, "The rollout waves must include every current participant exactly once."
    assert_empty @cohort.cohort_rollouts
  end

  test "advances only a ready next wave then pauses resumes and completes" do
    @second.update!(invitation_status: "pending", clerk_id: "pending_#{SecureRandom.hex(6)}")
    rollout = plan!(waves: [
      { name: "Ready first", user_ids: [ @first.id ] },
      { name: "Waiting second", user_ids: [ @second.id ] }
    ]).rollout

    activated = @machine.advance!(rollout: rollout, input: advance_input(rollout))
    assert_equal "activated", activated.transition.event_type
    assert_equal "active", rollout.reload.status
    assert_equal 1, rollout.current_wave_position

    blocked_input = advance_input(rollout)
    error = assert_raises(CohortRollouts::StateMachine::Ineligible) do
      @machine.advance!(rollout: rollout, input: blocked_input)
    end
    assert_includes error.blockers, "Every participant in wave 2 must be ready before it can advance."

    @second.update!(invitation_status: "accepted", clerk_id: "clerk_#{SecureRandom.hex(6)}")
    assert_raises(CohortRollouts::StateMachine::Stale) do
      @machine.advance!(rollout: rollout, input: blocked_input)
    end

    advanced = @machine.advance!(rollout: rollout, input: advance_input(rollout.reload))
    assert_equal "advanced", advanced.transition.event_type
    assert_equal 2, rollout.reload.current_wave_position

    paused = @machine.pause!(rollout: rollout, input: cas_input(rollout.reload))
    assert_equal "paused", paused.rollout.reload.status
    resumed = @machine.resume!(rollout: rollout, input: cas_input(rollout.reload))
    assert_equal "active", resumed.rollout.reload.status

    completed = @machine.advance!(rollout: rollout, input: advance_input(rollout.reload))
    assert_equal "completed", completed.transition.event_type
    assert_equal "completed", rollout.reload.status
    assert_equal 2, rollout.current_wave_position
    assert rollout.transitions.where(event_type: %w[activated advanced completed]).all? { |row| row.readiness_digest.present? }
  end

  test "cancels only an unstarted rollout" do
    rollout = plan!.rollout
    result = @machine.cancel!(rollout: rollout, input: cas_input(rollout))

    assert_equal "cancelled", result.transition.event_type
    assert_equal "cancelled", rollout.reload.status
    assert_raises(CohortRollouts::StateMachine::InvalidTransition) do
      @machine.cancel!(rollout: rollout, input: cas_input(rollout))
    end
  end

  test "completion rechecks the final wave instead of hashing an empty participant set" do
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))
    @first.update!(invitation_status: "revoked")

    digest = CohortRollouts::Contract.readiness_digest_for_advance(rollout.reload)
    snapshot = CohortRollouts::Contract.wave_readiness_snapshot(
      rollout,
      rollout.waves.find_by!(position: rollout.current_wave_position)
    )
    assert_equal digest, CohortRollouts::Contract.digest(snapshot)
    assert_equal [ @first.id, @second.id ], snapshot.fetch("participants").pluck("user_id").sort

    error = assert_raises(CohortRollouts::StateMachine::Ineligible) do
      @machine.advance!(rollout: rollout, input: advance_input(rollout))
    end
    assert_includes error.blockers, "Every participant in wave 1 must be ready before it can complete."
    assert_equal "active", rollout.reload.status
  end

  test "rolls an active plan back only to an earlier compatible release" do
    older_release = @release
    candidate = CohortReleases::CandidateBuilder.new(cohort: @cohort, strict: false).call
    latest_release = CohortReleases::Sealer.new(
      cohort: @cohort,
      actor: nil,
      publication_source: "system"
    ).call!(request_key: "rollout-target", expected_bundle_digest: candidate.bundle_digest)
    @release = latest_release
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))

    result = @machine.rollback!(
      rollout: rollout,
      input: cas_input(rollout.reload).merge(rollback_release_id: older_release.id)
    )

    assert_equal "rolled_back", result.transition.event_type
    assert_equal older_release, rollout.reload.rollback_cohort_release
    assert_equal false, result.after_snapshot.fetch("participant_runtime_changed")
  end

  test "studio keeps history bounded and shows live removed readiness without exposing email" do
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))
    @cohort.cohort_memberships.find_by!(user: @second).destroy!

    payload = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
    serialized = payload.fetch(:open_rollout)
    second = serialized.fetch(:waves).flat_map { |wave| wave.fetch(:participants) }
      .find { |participant| participant.fetch(:user_id) == @second.id }

    assert_equal "removed", second.fetch(:readiness)
    assert_equal false, payload.dig(:runtime_truth, :participant_runtime_changed)
    assert_equal CohortRollouts::Contract.roster_digest(@cohort), payload.dig(:current_roster, :digest)
    assert_equal CohortRollouts::Contract.readiness_digest(cohort: @cohort),
      payload.dig(:current_roster, :readiness_digest)
    assert_equal CohortRollouts::Contract.rollout_readiness_digest(rollout),
      serialized.fetch(:readiness_digest)
    assert_equal CohortRollouts::Contract.readiness_digest_for_advance(rollout),
      serialized.fetch(:next_wave_readiness_digest)
    assert_equal 25, payload.dig(:history, :limit)
    assert_equal false, payload.dig(:history, :truncated)
    refute_includes payload.to_json, "@example.com"
  end

  test "studio does not advertise rollback when the target is the first release" do
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))

    permissions = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
      .dig(:open_rollout, :permissions)

    assert_equal false, permissions.fetch(:rollback)
    assert_equal [ "No earlier sealed release is available for rollback." ],
      permissions.fetch(:rollback_blockers)
  end

  test "studio skips rollback candidate searches for planned and terminal rollouts" do
    rollout = plan!.rollout

    planned_payload, planned_queries = capture_sql do
      CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call_with_rollout(rollout).last
    end
    assert_nil planned_payload.fetch(:rollback_candidate)
    assert_empty rollback_candidate_queries(planned_queries)

    @machine.cancel!(rollout: rollout, input: cas_input(rollout))
    terminal_payload, terminal_queries = capture_sql do
      CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call_with_rollout(rollout.reload).last
    end
    assert_nil terminal_payload.fetch(:rollback_candidate)
    assert_empty rollback_candidate_queries(terminal_queries)
  end

  test "studio advertises rollback only when an earlier release is compatible" do
    older_release = @release
    @release = seal_next_release!(request_key: "compatible-rollout-target")
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))

    compatible_rollout = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
      .fetch(:open_rollout)
    compatible_permissions = compatible_rollout.fetch(:permissions)
    assert compatible_permissions.fetch(:rollback)
    assert_empty compatible_permissions.fetch(:rollback_blockers)
    assert_equal older_release.id, compatible_rollout.dig(:rollback_candidate, :id)

    begin
      CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
      older_release.update_columns(bundle_digest: "0" * 64)
    ensure
      CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
    end

    incompatible_permissions = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
      .dig(:open_rollout, :permissions)
    assert_equal false, incompatible_permissions.fetch(:rollback)
    assert_equal [ "No earlier release passed integrity and runtime compatibility checks." ],
      incompatible_permissions.fetch(:rollback_blockers)
  end

  test "studio returns an eligible rollback candidate outside bounded release history" do
    releases = [ @release ]
    26.times do |index|
      releases << seal_next_release!(request_key: "deep-rollback-release-#{index + 2}")
    end
    @release = releases.last
    corrupted = releases[1...-1]
    begin
      CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
      CohortRelease.where(id: corrupted.map(&:id)).update_all(bundle_digest: "0" * 64)
    ensure
      CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
    end
    rollout = plan!.rollout
    @machine.advance!(rollout: rollout, input: advance_input(rollout))

    payload, queries = capture_sql do
      CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
    end
    serialized = payload.fetch(:open_rollout)

    assert_equal 25, payload.fetch(:releases).length
    refute_includes payload.fetch(:releases).pluck(:id), releases.first.id
    assert serialized.dig(:permissions, :rollback)
    assert_equal releases.first.id, serialized.dig(:rollback_candidate, :id)
    assert_equal 2, rollback_candidate_queries(queries).length
  end

  test "studio advertises planning only when a release and participant roster are usable" do
    CohortReleases::RuntimeActivator.new(cohort: @cohort).call!
    @release = seal_next_release!(request_key: "studio-runtime-target")
    valid = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
    assert valid.dig(:permissions, :plan)
    assert_empty valid.dig(:permissions, :plan_blockers)

    no_release = Cohort.create!(
      name: "No release #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: @owner,
      coach_workspace: @cohort.coach_workspace
    )
    no_release.cohort_memberships.create!(user: create_user, role: "participant")
    missing_release = CohortRollouts::StudioSerializer.new(cohort: no_release, actor: @owner).call
    assert_equal false, missing_release.dig(:permissions, :plan)
    assert_includes missing_release.dig(:permissions, :plan_blockers),
      "Seal a cohort release before planning a rollout."

    @cohort.cohort_memberships.where(role: "participant").delete_all
    empty_roster = CohortRollouts::StudioSerializer.new(cohort: @cohort.reload, actor: @owner).call
    assert_equal false, empty_roster.dig(:permissions, :plan)
    assert_includes empty_roster.dig(:permissions, :plan_blockers),
      "Add at least one participant before planning a rollout."
  end

  test "studio blocks planning when the latest release is runtime incompatible" do
    begin
      CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
      @release.update_columns(tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION + 1)
    ensure
      CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
    end

    payload = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call

    assert_equal false, payload.dig(:permissions, :plan)
    assert_includes payload.dig(:permissions, :plan_blockers),
      "The latest sealed release is not compatible with the current runtime."
  end

  test "studio uses transition IDs as canonical order when wall clock moves backward" do
    planned = nil
    activated = nil
    travel_to(Time.utc(2026, 10, 3, 12)) { planned = plan!.transition }
    rollout = planned.cohort_rollout
    travel_to(Time.utc(2026, 10, 3, 11)) do
      activated = @machine.advance!(rollout: rollout, input: advance_input(rollout)).transition
    end

    payload = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call
      .fetch(:open_rollout)
    assert_operator activated.id, :>, planned.id
    assert_operator activated.occurred_at, :<, planned.occurred_at
    assert_equal activated.id, payload.fetch(:latest_transition_id)
    assert_equal [ activated.id, planned.id ], payload.fetch(:transitions).pluck(:id)
    assert_equal activated.readiness_digest, payload.fetch(:transitions).first.fetch(:readiness_digest)
  end

  test "studio exposes legacy closed-cohort cancellation as the only mutation" do
    rollout = plan!.rollout
    begin
      Cohort.connection.execute("ALTER TABLE cohorts DISABLE TRIGGER cohorts_open_rollout_lifecycle_guard")
      Cohort.where(id: @cohort.id).update_all(status: "completed")
    ensure
      Cohort.connection.execute("ALTER TABLE cohorts ENABLE TRIGGER cohorts_open_rollout_lifecycle_guard")
    end

    payload = CohortRollouts::StudioSerializer.new(cohort: @cohort.reload, actor: @owner).call
    assert payload.dig(:permissions, :manage)
    assert_equal false, payload.dig(:permissions, :plan)
    assert payload.dig(:open_rollout, :permissions, :cancel)
    assert_equal false, payload.dig(:open_rollout, :permissions, :advance)
    assert_equal rollout.id, payload.dig(:open_rollout, :id)
  end

  test "studio returns only the newest twenty five immutable rollout records" do
    26.times do
      rollout = plan!.rollout
      @machine.cancel!(rollout: rollout, input: cas_input(rollout))
    end

    payload = CohortRollouts::StudioSerializer.new(cohort: @cohort, actor: @owner).call

    assert_equal 25, payload.fetch(:rollouts).length
    assert_equal 26, payload.dig(:history, :total_count)
    assert_equal true, payload.dig(:history, :truncated)
    assert_nil payload.fetch(:open_rollout)
    assert_operator payload.fetch(:rollouts).first.fetch(:id), :>, payload.fetch(:rollouts).last.fetch(:id)
  end

  private

  def create_user(role: "participant", invitation_status: "accepted", first_name: nil, last_name: nil)
    pending = invitation_status == "pending"
    User.create!(
      clerk_id: pending ? "pending_#{SecureRandom.hex(8)}" : "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: invitation_status,
      first_name: first_name,
      last_name: last_name
    )
  end

  def plan!(waves: nil)
    waves ||= [ { name: "All households", user_ids: [ @first.id, @second.id ] } ]
    @machine.plan!(plan_input(waves: waves))
  end

  def seal_next_release!(request_key:)
    candidate = CohortReleases::CandidateBuilder.new(cohort: @cohort, strict: false).call
    CohortReleases::Sealer.new(
      cohort: @cohort,
      actor: nil,
      publication_source: "system"
    ).call!(request_key: request_key, expected_bundle_digest: candidate.bundle_digest)
  end

  def plan_input(waves:)
    {
      target_release_id: @release.id,
      expected_latest_release_id: @release.id,
      expected_roster_digest: CohortRollouts::Contract.roster_digest(@cohort),
      waves: waves
    }
  end

  def cas_input(rollout)
    {
      expected_status: rollout.status,
      expected_current_wave_position: rollout.current_wave_position,
      expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id)
    }
  end

  def advance_input(rollout)
    cas_input(rollout).merge(readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout))
  end

  def capture_sql
    queries = []
    result = nil
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      queries << payload.fetch(:sql) unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      result = yield
    end
    [ result, queries ]
  end

  def rollback_candidate_queries(queries)
    queries.grep(/release_number < /)
  end
end
