# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachOperationsRolloutTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "runner records and replays a reviewed rollout plan as immutable evidence" do
    owner, cohort, first_release, target_release, participants = rollout_components
    input = plan_input(cohort, target_release, participants)

    first = run_operation(cohort, owner, "cohort.rollout.plan", input, "rollout-plan-1")
    replay = run_operation(cohort, owner, "cohort.rollout.plan", input, "rollout-plan-1")

    assert_equal false, first.replayed
    assert_equal true, replay.replayed
    assert_nil first.release
    assert_equal first.transition, first.record
    assert_equal first.execution, replay.execution
    assert_equal first.rollout, replay.rollout
    assert_equal "planned", first.transition.event_type
    assert_equal target_release, first.rollout.target_cohort_release
    assert_equal [ participants.first.id, participants.second.id ],
      first.rollout.participants.order(:cohort_rollout_wave_id, :user_id).pluck(:user_id)
    assert_equal false, first.execution.after_snapshot.fetch("participant_runtime_changed")
    assert_nil first.execution.cohort_release
    assert_equal first.transition, first.execution.cohort_rollout_transition
    assert_equal first_release, cohort.cohort_releases.order(:release_number).first
    assert_equal 1, cohort.coach_operation_executions.count
  end

  test "six typed rollout operations preserve CAS evidence and never change participant runtime" do
    owner, cohort, first_release, target_release, participants = rollout_components
    runtime_before = participant_runtime_snapshot(cohort, participants)
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "rollout-lifecycle-plan"
    )
    rollout = plan.rollout

    activation = run_operation(
      cohort,
      owner,
      "cohort.rollout.advance",
      transition_input(rollout).merge(
        "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(rollout)
      ),
      "rollout-lifecycle-activate"
    )
    assert_equal "activated", activation.transition.event_type
    assert_equal 1, rollout.reload.current_wave_position
    assert_equal activation.transition.readiness_digest,
      activation.execution.normalized_input.fetch("readiness_digest")

    pause = run_operation(
      cohort, owner, "cohort.rollout.pause", transition_input(rollout), "rollout-lifecycle-pause"
    )
    assert_equal "paused", pause.transition.event_type
    assert_equal activation.transition.id,
      pause.execution.normalized_input.fetch("expected_latest_transition_id")

    resume_result = run_operation(
      cohort, owner, "cohort.rollout.resume", transition_input(rollout.reload), "rollout-lifecycle-resume"
    )
    assert_equal "resumed", resume_result.transition.event_type
    assert_equal pause.transition.id,
      resume_result.execution.normalized_input.fetch("expected_latest_transition_id")

    rollback = run_operation(
      cohort,
      owner,
      "cohort.rollout.rollback",
      transition_input(rollout.reload).merge("rollback_release_id" => first_release.id),
      "rollout-lifecycle-rollback"
    )
    assert_equal "rolled_back", rollback.transition.event_type
    assert_equal first_release, rollout.reload.rollback_cohort_release

    second_plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "rollout-cancel-plan"
    )
    cancelled = run_operation(
      cohort,
      owner,
      "cohort.rollout.cancel",
      transition_input(second_plan.rollout),
      "rollout-cancel"
    )
    assert_equal "cancelled", cancelled.transition.event_type

    transitions = CohortRolloutTransition.where(cohort: cohort).order(:id)
    assert_equal %w[planned activated paused resumed rolled_back planned cancelled], transitions.pluck(:event_type)
    assert transitions.all? { |transition| transition.participant_runtime_changed == false }
    assert cohort.coach_operation_executions.all? { |execution|
      execution.after_snapshot.fetch("participant_runtime_changed") == false
    }
    assert_equal runtime_before, participant_runtime_snapshot(cohort, participants)
  end

  test "request keys conflict globally within a cohort across release and rollout operations" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    input = plan_input(cohort, target_release, participants)
    run_operation(cohort, owner, "cohort.rollout.plan", input, "shared-request-key")

    error = assert_raises(CoachOperations::Runner::IdempotencyConflict) do
      run_operation(
        cohort,
        owner,
        "cohort.rollout.cancel",
        transition_input(cohort.cohort_rollouts.sole),
        "shared-request-key"
      )
    end
    assert_includes error.message, "different coach operation"
    assert_equal 1, cohort.coach_operation_executions.count
  end

  test "transition and execution are one transaction" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    input = plan_input(cohort, target_release, participants)

    proxy_class = cohort.coach_operation_executions.class
    original_create = proxy_class.instance_method(:create!)
    proxy_class.define_method(:create!) do |attributes = nil, &block|
      if attributes.is_a?(Hash) && attributes.key?(:operation_key)
        raise ActiveRecord::RecordInvalid.new(CoachOperationExecution.new)
      end

      original_create.bind_call(self, attributes, &block)
    end
    begin
      assert_raises(ActiveRecord::RecordInvalid) do
        run_operation(cohort, owner, "cohort.rollout.plan", input, "atomic-rollout-plan")
      end
    ensure
      proxy_class.define_method(:create!, original_create)
    end

    assert_empty cohort.cohort_rollouts
    assert_empty CohortRolloutTransition.where(cohort: cohort)
    assert_empty cohort.coach_operation_executions
  end

  test "direct execution creation cannot forge rollout transition linkage or readiness evidence" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "forgery-plan"
    )
    advance = run_operation(
      cohort,
      owner,
      "cohort.rollout.advance",
      transition_input(plan.rollout).merge(
        "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(plan.rollout)
      ),
      "forgery-advance"
    )

    forged = advance.execution.dup
    forged.normalized_input = forged.normalized_input.merge("readiness_digest" => "f" * 64)
    reset_execution_fingerprints(forged)
    refute forged.valid?
    assert_includes forged.errors[:normalized_input], "does not match the linked rollout transition"

    forged = advance.execution.dup
    forged.after_snapshot = forged.after_snapshot.merge("participant_runtime_changed" => true)
    forged.after_snapshot_digest = CoachOperations::Contract.digest(forged.after_snapshot)
    refute forged.valid?
    assert_includes forged.errors[:after_snapshot], "does not match the linked rollout transition"

    both_results = advance.execution.dup
    both_results.cohort_release = target_release
    refute both_results.valid?
    assert_includes both_results.errors[:base], "must link exactly one immutable operation result"

    no_result = advance.execution.attributes.except("id", "cohort_release_id", "cohort_rollout_transition_id")
    no_result["request_key"] = "forged-no-result"
    no_result["request_fingerprint"] = CoachOperations::Contract.request_fingerprint(
      request_key: no_result.fetch("request_key"),
      invocation_fingerprint: no_result.fetch("invocation_fingerprint")
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.insert_all!([ no_result ])
    end
  end

  test "database rejects operation keys crossed with the other result family" do
    owner, cohort, first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "crossed-result-plan"
    )

    release_result = plan.execution.attributes.except("id", "created_at", "updated_at").merge(
      "cohort_release_id" => first_release.id,
      "cohort_rollout_transition_id" => nil,
      "request_key" => "rollout-key-release-result",
      "created_at" => Time.current,
      "updated_at" => Time.current
    )
    error = assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.transaction(requires_new: true) do
        CoachOperationExecution.insert_all!([ release_result ])
      end
    end
    assert_includes error.message, "coach_operations_result_matches_key"

    error = assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.transaction(requires_new: true) do
        occurred_at = Time.current
        plan.rollout.update!(status: "cancelled", cancelled_at: occurred_at)
        transition = plan.rollout.transitions.create!(
          actor_user: owner,
          actor_role_snapshot: "owner",
          event_type: "cancelled",
          from_status: "planned",
          to_status: "cancelled",
          from_wave_position: 0,
          to_wave_position: 0,
          participant_runtime_changed: false,
          occurred_at: occurred_at
        )
        rollout_result = plan.execution.attributes.except("id", "created_at", "updated_at").merge(
          "operation_key" => "cohort.release.seal",
          "cohort_release_id" => nil,
          "cohort_rollout_transition_id" => transition.id,
          "request_key" => "release-key-rollout-result",
          "completed_at" => occurred_at,
          "created_at" => occurred_at,
          "updated_at" => occurred_at
        )
        CoachOperationExecution.insert_all!([ rollout_result ])
      end
    end
    assert_includes error.message, "coach_operations_result_matches_key"
  end

  test "runner output satisfies deferred rollout integrity at the database boundary" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    result = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "deferred-integrity-plan"
    )

    set_rollout_constraints("IMMEDIATE")

    assert_equal result.transition.id, result.rollout.transitions.order(:id).last.id
    assert_equal result.execution, result.transition.coach_operation_execution
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "incremental integrity stays bounded across several hundred pause and resume appends" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "bounded-append-plan"
    )
    rollout = plan.rollout
    run_operation(
      cohort,
      owner,
      "cohort.rollout.advance",
      transition_input(rollout).merge(
        "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(rollout)
      ),
      "bounded-append-activate"
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    150.times do |index|
      run_operation(
        cohort,
        owner,
        "cohort.rollout.pause",
        transition_input(rollout),
        "bounded-append-pause-#{index}"
      )
      run_operation(
        cohort,
        owner,
        "cohort.rollout.resume",
        transition_input(rollout),
        "bounded-append-resume-#{index}"
      )
    end
    set_rollout_constraints("IMMEDIATE")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_equal 302, rollout.transitions.count
    assert_equal 302, cohort.coach_operation_executions.where.not(cohort_rollout_transition_id: nil).count
    assert_operator elapsed, :<=, 15.0,
      "302 immutable rollout appends and deferred validation took #{elapsed.round(3)} seconds"
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "deferred integrity rejects bulk inserted execution evidence with the wrong operation" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "bulk-forgery-plan"
    )
    error = assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.transaction(requires_new: true) do
        occurred_at = Time.current
        plan.rollout.update!(status: "cancelled", cancelled_at: occurred_at)
        transition = plan.rollout.transitions.create!(
          actor_user: owner,
          actor_role_snapshot: "owner",
          event_type: "cancelled",
          from_status: "planned",
          to_status: "cancelled",
          from_wave_position: 0,
          to_wave_position: 0,
          participant_runtime_changed: false,
          occurred_at: occurred_at
        )
        forged = plan.execution.attributes.except("id", "created_at", "updated_at")
        forged.merge!(
          "cohort_rollout_transition_id" => transition.id,
          "operation_key" => "cohort.rollout.plan",
          "request_key" => "bulk-forged-operation",
          "completed_at" => occurred_at,
          "created_at" => occurred_at,
          "updated_at" => occurred_at
        )
        CoachOperationExecution.insert_all!([ forged ])
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "rollout operation identity does not match its transition"
  end

  test "deferred integrity rejects raw planned attribution that differs from the rollout planner" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    other_actor = persona_user
    error = assert_raises(ActiveRecord::StatementInvalid) do
      CohortRollout.transaction(requires_new: true) do
        occurred_at = Time.current
        rollout = CohortRollout.create!(
          cohort: cohort,
          coach_workspace: cohort.coach_workspace,
          target_cohort_release: target_release,
          planned_by_user: owner,
          planned_by_role_snapshot: "owner",
          status: "planned",
          current_wave_position: 0,
          planned_at: occurred_at
        )
        inserted_wave = CohortRolloutWave.insert_all!([ {
          cohort_rollout_id: rollout.id,
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          position: 1,
          name: "All households",
          created_at: occurred_at,
          updated_at: occurred_at
        } ], returning: %w[id])
        wave_id = inserted_wave.rows.sole.sole
        CohortRolloutParticipant.insert_all!(participants.map do |participant|
          {
            cohort_rollout_id: rollout.id,
            cohort_rollout_wave_id: wave_id,
            cohort_id: cohort.id,
            coach_workspace_id: cohort.coach_workspace_id,
            user_id: participant.id,
            created_at: occurred_at,
            updated_at: occurred_at
          }
        end)
        CohortRolloutTransition.insert_all!([ {
          cohort_rollout_id: rollout.id,
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          actor_user_id: other_actor.id,
          actor_role_snapshot: "owner",
          event_type: "planned",
          from_status: nil,
          to_status: "planned",
          from_wave_position: nil,
          to_wave_position: 0,
          readiness_digest: nil,
          rollback_cohort_release_id: nil,
          participant_runtime_changed: false,
          occurred_at: occurred_at,
          created_at: occurred_at,
          updated_at: occurred_at
        } ])
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "planned rollout attribution must match the immutable planner"
  end

  test "deferred integrity rejects rollout snapshots with unapproved JSON keys" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "exact-snapshot-plan"
    )

    error = assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.transaction(requires_new: true) do
        rollout = plan.rollout.reload
        normalized_input = transition_input(rollout)
        before_snapshot = CohortRollouts::Contract.state_snapshot(cohort: cohort, rollout: rollout)
        predicted_after_snapshot = before_snapshot.merge(
          "status" => "cancelled",
          "latest_transition_id" => nil,
          "latest_transition_id_pending" => true
        )
        occurred_at = Time.current
        rollout.update!(status: "cancelled", cancelled_at: occurred_at)
        transition = rollout.transitions.create!(
          actor_user: owner,
          actor_role_snapshot: "owner",
          event_type: "cancelled",
          from_status: "planned",
          to_status: "cancelled",
          from_wave_position: 0,
          to_wave_position: 0,
          participant_runtime_changed: false,
          occurred_at: occurred_at
        )
        after_snapshot = CohortRollouts::Contract.state_snapshot(
          cohort: cohort,
          rollout: rollout.reload
        ).merge("sensitive_extra" => "must not be stored")
        invocation_fingerprint = CoachOperations::Contract.invocation_fingerprint(
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          actor_user_id: owner.id,
          actor_role_snapshot: "owner",
          operation_key: "cohort.rollout.cancel",
          operation_version: 1,
          normalized_input: normalized_input
        )
        request_key = "exact-snapshot-forgery"
        CoachOperationExecution.insert_all!([ {
          coach_workspace_id: cohort.coach_workspace_id,
          cohort_id: cohort.id,
          actor_user_id: owner.id,
          actor_role_snapshot: "owner",
          operation_key: "cohort.rollout.cancel",
          operation_version: 1,
          source: "api",
          request_key: request_key,
          invocation_fingerprint: invocation_fingerprint,
          request_fingerprint: CoachOperations::Contract.request_fingerprint(
            request_key: request_key,
            invocation_fingerprint: invocation_fingerprint
          ),
          normalized_input: normalized_input,
          normalized_input_digest: CoachOperations::Contract.digest(normalized_input),
          before_snapshot: before_snapshot,
          before_snapshot_digest: CoachOperations::Contract.digest(before_snapshot),
          predicted_after_snapshot: predicted_after_snapshot,
          predicted_after_snapshot_digest: CoachOperations::Contract.digest(predicted_after_snapshot),
          after_snapshot: after_snapshot,
          after_snapshot_digest: CoachOperations::Contract.digest(after_snapshot),
          cohort_release_id: nil,
          cohort_rollout_transition_id: transition.id,
          completed_at: occurred_at,
          created_at: occurred_at,
          updated_at: occurred_at
        } ])
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "rollout operation snapshots do not match exact relational evidence"
  end

  test "deferred rollout insert requires the immutable roster to equal current participants" do
    owner, cohort, _first_release, target_release, participants = rollout_components

    error = assert_raises(ActiveRecord::StatementInvalid) do
      CohortRollout.transaction(requires_new: true) do
        run_operation(
          cohort,
          owner,
          "cohort.rollout.plan",
          plan_input(cohort, target_release, participants),
          "roster-equality-plan"
        )
        omitted = persona_user(
          role: "participant",
          email: "omitted-#{SecureRandom.hex(4)}@example.com"
        )
        cohort.cohort_memberships.create!(user: omitted, role: "participant")
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "planned rollout roster must exactly match current cohort participants"
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "deferred integrity rejects a rollout target that stopped being the latest release" do
    owner, cohort, _first_release, target_release, participants = rollout_components

    error = assert_raises(ActiveRecord::StatementInvalid) do
      CohortRollout.transaction(requires_new: true) do
        run_operation(
          cohort,
          owner,
          "cohort.rollout.plan",
          plan_input(cohort, target_release, participants),
          "latest-release-race-plan"
        )
        candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
        CohortReleases::Sealer.new(
          cohort: cohort,
          actor: nil,
          publication_source: "system"
        ).call!(request_key: "latest-release-race-newer", expected_bundle_digest: candidate.bundle_digest)
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "planned rollout must target the latest sealed release"
    assert_empty cohort.reload.cohort_rollouts
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "deferred integrity rejects rollback to the rollout target release" do
    owner, cohort, _first_release, target_release, participants = rollout_components
    plan = run_operation(
      cohort,
      owner,
      "cohort.rollout.plan",
      plan_input(cohort, target_release, participants),
      "rollback-order-plan"
    )
    run_operation(
      cohort,
      owner,
      "cohort.rollout.advance",
      transition_input(plan.rollout).merge(
        "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(plan.rollout)
      ),
      "rollback-order-activate"
    )

    error = assert_raises(ActiveRecord::StatementInvalid) do
      CohortRollout.transaction(requires_new: true) do
        occurred_at = Time.current
        rollout = plan.rollout.reload
        rollout.update_columns(
          status: "rolled_back",
          rollback_cohort_release_id: target_release.id,
          rolled_back_at: occurred_at,
          updated_at: occurred_at
        )
        CohortRolloutTransition.insert_all!([ {
          cohort_rollout_id: rollout.id,
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          actor_user_id: owner.id,
          actor_role_snapshot: "owner",
          event_type: "rolled_back",
          from_status: "active",
          to_status: "rolled_back",
          from_wave_position: 1,
          to_wave_position: 1,
          readiness_digest: nil,
          rollback_cohort_release_id: target_release.id,
          participant_runtime_changed: false,
          occurred_at: occurred_at,
          created_at: occurred_at,
          updated_at: occurred_at
        } ])
        set_rollout_constraints("IMMEDIATE")
      end
    end

    assert_includes error.message, "rollback release must predate the rollout target release"
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "deferred integrity rejects a rollout plan with noncontiguous waves" do
    owner, cohort, _first_release, target_release, participants = rollout_components

    error = assert_raises(ActiveRecord::StatementInvalid) do
      insert_raw_plan_shape!(
        owner: owner,
        cohort: cohort,
        target_release: target_release,
        wave_positions: [ 1, 3 ],
        participant_wave_indexes: [ 0, 1 ],
        participants: participants
      )
    end

    assert_includes error.message, "rollout waves must be contiguous, bounded, and nonempty"
  ensure
    set_rollout_constraints("DEFERRED")
  end

  test "deferred integrity rejects a rollout plan with an empty wave" do
    owner, cohort, _first_release, target_release, participants = rollout_components

    error = assert_raises(ActiveRecord::StatementInvalid) do
      insert_raw_plan_shape!(
        owner: owner,
        cohort: cohort,
        target_release: target_release,
        wave_positions: [ 1, 2 ],
        participant_wave_indexes: [ 0, 0 ],
        participants: participants
      )
    end

    assert_includes error.message, "rollout waves must be contiguous, bounded, and nonempty"
  ensure
    set_rollout_constraints("DEFERRED")
  end

  private

  def rollout_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Rollout operations #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    participant_count = cohort.cohort_memberships.where(role: "participant").count
    participants = 2.times.map do |index|
      user = persona_user(role: "participant", email: "rollout-#{index}-#{SecureRandom.hex(4)}@example.com")
      CohortMembership.create!(cohort: cohort, user: user, role: "participant")
      user
    end
    assert_equal participant_count + 2, cohort.cohort_memberships.where(role: "participant").count

    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    first_release = CohortReleases::Sealer.new(
      cohort: cohort,
      actor: nil,
      publication_source: "system"
    ).call!(request_key: "rollout-system-release-1", expected_bundle_digest: candidate.bundle_digest)
    target_release = CohortReleases::Sealer.new(
      cohort: cohort,
      actor: nil,
      publication_source: "system"
    ).call!(request_key: "rollout-system-release-2", expected_bundle_digest: candidate.bundle_digest)
    [ owner, cohort, first_release, target_release, participants ]
  end

  def insert_raw_plan_shape!(owner:, cohort:, target_release:, wave_positions:, participant_wave_indexes:,
    participants:)
    CohortRollout.transaction(requires_new: true) do
      occurred_at = Time.current
      rollout = CohortRollout.create!(
        cohort: cohort,
        coach_workspace: cohort.coach_workspace,
        target_cohort_release: target_release,
        planned_by_user: owner,
        planned_by_role_snapshot: "owner",
        status: "planned",
        current_wave_position: 0,
        planned_at: occurred_at
      )
      inserted_waves = CohortRolloutWave.insert_all!(wave_positions.map do |position|
        {
          cohort_rollout_id: rollout.id,
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          position: position,
          name: "Wave #{position}",
          created_at: occurred_at,
          updated_at: occurred_at
        }
      end, returning: %w[id position])
      wave_ids = inserted_waves.rows.to_h { |id, position| [ position, id ] }
      CohortRolloutParticipant.insert_all!(participants.each_with_index.map do |participant, index|
        position = wave_positions.fetch(participant_wave_indexes.fetch(index))
        {
          cohort_rollout_id: rollout.id,
          cohort_rollout_wave_id: wave_ids.fetch(position),
          cohort_id: cohort.id,
          coach_workspace_id: cohort.coach_workspace_id,
          user_id: participant.id,
          created_at: occurred_at,
          updated_at: occurred_at
        }
      end)
      set_rollout_constraints("IMMEDIATE")
    end
  end

  def plan_input(cohort, target_release, participants)
    {
      "target_release_id" => target_release.id,
      "expected_latest_release_id" => target_release.id,
      "expected_roster_digest" => CohortRollouts::Contract.roster_digest(cohort),
      "waves" => participants.each_with_index.map do |participant, index|
        { "name" => "Wave #{index + 1}", "user_ids" => [ participant.id ] }
      end
    }
  end

  def transition_input(rollout)
    rollout.reload
    {
      "rollout_id" => rollout.id,
      "expected_status" => rollout.status,
      "expected_current_wave_position" => rollout.current_wave_position,
      "expected_latest_transition_id" => rollout.transitions.reorder(id: :desc).pick(:id)
    }
  end

  def run_operation(cohort, owner, key, input, request_key)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: key,
      operation_version: 1,
      input: input,
      request_key: request_key
    )
  end

  def reset_execution_fingerprints(execution)
    execution.normalized_input_digest = CoachOperations::Contract.digest(execution.normalized_input)
    execution.invocation_fingerprint = CoachOperations::Contract.invocation_fingerprint(
      cohort_id: execution.cohort_id,
      coach_workspace_id: execution.coach_workspace_id,
      actor_user_id: execution.actor_user_id,
      actor_role_snapshot: execution.actor_role_snapshot,
      operation_key: execution.operation_key,
      operation_version: execution.operation_version,
      normalized_input: execution.normalized_input
    )
    execution.request_fingerprint = CoachOperations::Contract.request_fingerprint(
      request_key: execution.request_key,
      invocation_fingerprint: execution.invocation_fingerprint
    )
  end

  def participant_runtime_snapshot(cohort, participants)
    assignment = cohort.cohort_persona_assignment
    configuration = cohort.cohort_experience_configuration
    {
      cohort_status: cohort.reload.status,
      memberships: cohort.cohort_memberships.order(:id).pluck(:id, :user_id, :role),
      users: User.where(id: participants.map(&:id)).order(:id).pluck(:id, :clerk_id, :invitation_status),
      persona_assignment: assignment && [
        assignment.id,
        assignment.coach_persona_id,
        assignment.coach_persona_version_id
      ],
      experience: [
        configuration.id,
        configuration.current_published_version_id,
        configuration.draft_revision,
        configuration.draft_config
      ],
      releases: cohort.cohort_releases.order(:release_number).pluck(:id, :bundle_digest)
    }
  end

  def set_rollout_constraints(mode)
    CoachOperationExecution.connection.execute(<<~SQL.squish)
      SET CONSTRAINTS cohort_rollouts_integrity_deferred,
        cohort_rollout_transitions_integrity_deferred,
        coach_operation_rollout_integrity_deferred #{mode}
    SQL
  end
end
