# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require "benchmark"

class CohortRuntimeDatabaseIntegrityTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "an active release pointer cannot change without same-transaction activation evidence" do
    owner = persona_user
    cohort = create_cohort(owner)
    release = seal_current_bundle(cohort, "unaudited-pointer")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        connection.execute("UPDATE cohorts SET active_cohort_release_id = #{release.id} WHERE id = #{cohort.id}")
        connection.execute("SET CONSTRAINTS cohort_active_release_change_integrity_deferred IMMEDIATE")
      end
    end
    assert_match(/exactly one matching activation event/, error.message)
  end

  test "activation evidence must match the current pointer and its claimed source" do
    owner = persona_user
    cohort = create_cohort(owner)
    baseline = seal_current_bundle(cohort, "pointer-baseline")
    CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    force_runtime_constraints!
    defer_constraints!
    target = seal_current_bundle(cohort, "pointer-target")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_activation_event(
          cohort: cohort,
          from_release_id: nil,
          to_release_id: target.id,
          event_type: "backfill",
          request_key: "mismatched-backfill"
        )
      end
    end
    assert_match(/must start from the current cohort release/, error.message)

    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    rollout = plan_rollout(owner, cohort, target, [ participant ])
    force_runtime_constraints!
    defer_constraints!
    advance(owner, rollout, "pointer-wave")
    force_runtime_constraints!
    defer_constraints!
    completion = advance(owner, rollout.reload, "pointer-complete")
    force_runtime_constraints!
    defer_constraints!
    third = seal_current_bundle(cohort, "pointer-third")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_activation_event(
          cohort: cohort,
          from_release_id: target.id,
          to_release_id: third.id,
          event_type: "rollout_completed",
          request_key: "mismatched-completion",
          rollout_id: rollout.id,
          transition_id: completion.transition.id,
          actor_user_id: owner.id,
          actor_role_snapshot: "owner"
        )
      end
    end
    assert_match(/must match its completed transition and release change/, error.message)
    assert_equal baseline.id, rollout.baseline_cohort_release_id
  end

  test "valid activator and rollout completion satisfy pointer evidence in both directions" do
    owner = persona_user
    cohort = create_cohort(owner)
    baseline = seal_current_bundle(cohort, "valid-baseline")
    activation = CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    force_runtime_constraints!
    defer_constraints!

    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    target = seal_current_bundle(cohort, "valid-target")
    rollout = plan_rollout(owner, cohort, target, [ participant ])
    force_runtime_constraints!
    defer_constraints!
    advance(owner, rollout, "valid-wave")
    force_runtime_constraints!
    defer_constraints!
    completion = advance(owner, rollout.reload, "valid-complete")
    force_runtime_constraints!

    assert_equal baseline.id, activation.release_id
    assert_equal "completed", completion.transition.event_type
    assert_equal target.id, cohort.reload.active_cohort_release_id
    event = cohort.cohort_release_activation_events.find_by!(cohort_rollout_transition: completion.transition)
    assert_equal [ baseline.id, target.id ], [ event.from_cohort_release_id, event.to_cohort_release_id ]
  end

  test "v2 rollout snapshots reject missing schemas missing fields and wrong values" do
    _owner, _cohort, baseline, _target, _participants, rollout, transition = advanced_rollout
    execution = transition.coach_operation_execution
    tamper_statements = [
      "before_snapshot = before_snapshot - 'schema'",
      "predicted_after_snapshot = predicted_after_snapshot - 'active_release_id'",
      "after_snapshot = jsonb_set(after_snapshot, '{baseline_release_id}', to_jsonb(#{baseline.id + 1_000_000}::bigint))"
    ]

    tamper_statements.each do |assignment|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute(
            "ALTER TABLE coach_operation_executions DISABLE TRIGGER coach_operation_executions_immutable"
          )
          connection.execute(<<~SQL)
            UPDATE coach_operation_executions
            SET #{assignment}
            WHERE id = #{execution.id}
          SQL
          connection.select_value("SELECT validate_cohort_rollout_transition_integrity(#{transition.id})")
        end
      end
      assert_match(/v2 rollout snapshots do not match runtime evidence/, error.message)
      execution.reload
    end
  end

  test "a maximum-size wave validates runtime evidence once per transaction" do
    owner = persona_user
    cohort = create_cohort(owner)
    baseline = seal_current_bundle(cohort, "max-wave-baseline")
    CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    force_runtime_constraints!
    defer_constraints!
    timestamp = Time.current
    suffix = SecureRandom.hex(5)
    inserted = User.insert_all!(
      CohortRollout::MAX_PARTICIPANTS.times.map do |index|
        {
          clerk_id: "clerk_max_wave_#{suffix}_#{index}",
          email: "max-wave-#{suffix}-#{index}@example.com",
          role: "participant",
          invitation_status: "accepted",
          invitation_email_status: "not_sent",
          created_at: timestamp,
          updated_at: timestamp
        }
      end,
      returning: %w[id]
    )
    participant_ids = inserted.rows.flatten
    CohortMembership.insert_all!(participant_ids.map do |user_id|
      {
        cohort_id: cohort.id,
        user_id: user_id,
        role: "participant",
        created_at: timestamp,
        updated_at: timestamp
      }
    end)
    target = seal_current_bundle(cohort, "max-wave-target")
    rollout = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan",
      operation_version: 2,
      input: {
        target_release_id: target.id,
        expected_latest_release_id: target.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: [ { name: "Maximum wave", user_ids: participant_ids } ]
      },
      request_key: "max-wave-plan"
    ).rollout
    force_runtime_constraints!
    defer_constraints!

    result = nil
    elapsed = Benchmark.realtime do
      result = advance(owner, rollout, "max-wave-advance")
      force_runtime_constraints!
    end
    defer_constraints!

    assert_equal CohortRollout::MAX_PARTICIPANTS,
      rollout.cohort_release_exposures.where(event_type: "wave").count
    validation_key = "household_cfo.runtime_transition_#{result.transition.id}"
    assert_equal connection.select_value("SELECT txid_current()::text"),
      connection.select_value("SELECT current_setting(#{connection.quote(validation_key)}, true)")
    assert_operator elapsed, :<, 15,
      "maximum wave evidence validation took #{elapsed.round(2)}s; transaction dedup may have regressed"
  end

  test "direct SQL rejects fictitious and cross-cohort membership epochs" do
    owner, cohort, _baseline, target, participants, rollout, transition = advanced_rollout
    wave = rollout.waves.find_by!(position: 2)
    participant = participants.second
    membership = cohort.cohort_memberships.find_by!(user: participant)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_exposure(
          cohort: cohort, rollout: rollout, transition: transition, wave: wave,
          release: target, participant: participant, membership_id: membership.id + 1_000_000,
          membership_started_at: membership.created_at, key: "fictitious-membership"
        )
      end
    end
    assert_match(/current participant membership epoch/, error.message)

    other = create_cohort(owner)
    other_membership = other.cohort_memberships.create!(user: participant, role: "participant")
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_exposure(
          cohort: cohort, rollout: rollout, transition: transition, wave: wave,
          release: target, participant: participant, membership_id: other_membership.id,
          membership_started_at: other_membership.created_at, key: "cross-cohort-membership"
        )
      end
    end
    assert_match(/current participant membership epoch/, error.message)
  end

  test "direct SQL cannot attribute a transition to the wrong wave or user" do
    _owner, cohort, _baseline, target, participants, rollout, transition = advanced_rollout
    participant = participants.second
    membership = cohort.cohort_memberships.find_by!(user: participant)
    wrong_wave = rollout.waves.find_by!(position: 2)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_exposure(
          cohort: cohort, rollout: rollout, transition: transition, wave: wrong_wave,
          release: target, participant: participant, membership_id: membership.id,
          membership_started_at: membership.created_at, key: "wrong-wave-user"
        )
        connection.execute("SET CONSTRAINTS cohort_release_exposures_integrity_deferred IMMEDIATE")
      end
    end
    assert_match(/wave exposure is incomplete/, error.message)
  end

  test "membership deletion preserves evidence while re-enrollment cannot reuse its old epoch" do
    _owner, cohort, baseline, target, participants, rollout, transition = advanced_rollout
    participant = participants.first
    old_membership = cohort.cohort_memberships.find_by!(user: participant)
    old_exposure = rollout.cohort_release_exposures.find_by!(user: participant, event_type: "wave")

    old_membership.destroy!
    replacement = cohort.cohort_memberships.create!(user: participant, role: "participant")

    assert CohortReleaseExposure.exists?(old_exposure.id)
    assert_equal baseline.id,
      Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: replacement).call.release_id
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        insert_exposure(
          cohort: cohort, rollout: rollout, transition: transition, wave: rollout.waves.first,
          release: target, participant: participant, membership_id: old_membership.id,
          membership_started_at: old_membership.created_at, key: "stale-membership-epoch"
        )
      end
    end
  end

  test "database blocks forward progress when an earlier exposed membership epoch changed" do
    owner, cohort, _baseline, _target, participants, rollout, _transition = advanced_rollout
    cohort.cohort_memberships.find_by!(user: participants.first).destroy!
    cohort.cohort_memberships.create!(user: participants.first, role: "participant")
    force_runtime_constraints!
    defer_constraints!
    eligibility_class = CohortRollouts::Eligibility
    original_membership_epoch_blockers = eligibility_class.instance_method(:membership_epoch_blockers)
    eligibility_class.define_method(:membership_epoch_blockers) { |_rollout| [] }

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        advance(owner, rollout.reload, "sql-changed-prior-epoch")
        connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      end
    end

    assert_match(/participant enrollment changed after planning/, error.message)
    assert_equal 1, rollout.reload.current_wave_position
    assert_equal "active", rollout.status
  ensure
    if original_membership_epoch_blockers
      eligibility_class&.define_method(:membership_epoch_blockers, original_membership_epoch_blockers)
    end
  end

  test "database rejects rollback exposure for a replacement membership epoch" do
    owner, cohort, baseline, _target, participants, rollout, _transition = advanced_rollout
    participant = participants.first
    cohort.cohort_memberships.find_by!(user: participant).destroy!
    replacement = cohort.cohort_memberships.create!(user: participant, role: "participant")
    force_runtime_constraints!
    defer_constraints!
    mutator_class = CohortRollouts::RuntimeMutator
    original_rollback = mutator_class.instance_method(:rollback!)
    mutator_class.define_method(:rollback!) do |transition:|
      planned = @rollout.participants.find_by!(user_id: participant.id)
      CohortReleaseExposure.create!(
        coach_workspace: @cohort.coach_workspace,
        cohort: @cohort,
        user_id: participant.id,
        cohort_membership_id: replacement.id,
        membership_started_at: replacement.created_at,
        cohort_release: @rollout.baseline_cohort_release,
        cohort_rollout: @rollout,
        cohort_rollout_wave: planned.cohort_rollout_wave,
        cohort_rollout_transition: transition,
        event_type: "rollback",
        exposure_key: "replacement-rollback:#{transition.id}:#{participant.id}",
        occurred_at: transition.occurred_at
      )
    end

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        rollout.reload
        CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
          operation_key: "cohort.rollout.rollback",
          operation_version: 2,
          input: {
            rollout_id: rollout.id,
            expected_status: rollout.status,
            expected_current_wave_position: rollout.current_wave_position,
            expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id),
            rollback_release_id: baseline.id
          },
          request_key: "replacement-rollback-#{SecureRandom.hex(3)}"
        )
        connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      end
    end

    assert_match(/rollback must restore the captured baseline/, error.message)
    assert_equal "active", rollout.reload.status
    assert_empty rollout.cohort_release_exposures.where(event_type: "rollback")
  ensure
    mutator_class&.define_method(:rollback!, original_rollback) if original_rollback
  end

  test "deferred integrity rejects a rollback that omits any previously exposed participant" do
    owner, cohort, baseline, _target, participants, rollout, _transition = advanced_rollout
    advance(owner, rollout.reload, "sql-second-wave-#{SecureRandom.hex(3)}")
    force_runtime_constraints!
    defer_constraints!
    mutator_class = CohortRollouts::RuntimeMutator
    original_rollback = mutator_class.instance_method(:rollback!)
    mutator_class.define_method(:rollback!) do |transition:|
      participant = @rollout.participants.order(:user_id).first
      membership = @cohort.cohort_memberships.find_by!(user_id: participant.user_id, role: "participant")
      CohortReleaseExposure.create!(
        coach_workspace: @cohort.coach_workspace,
        cohort: @cohort,
        user_id: participant.user_id,
        cohort_membership_id: membership.id,
        membership_started_at: membership.created_at,
        cohort_release: @rollout.baseline_cohort_release,
        cohort_rollout: @rollout,
        cohort_rollout_wave: participant.cohort_rollout_wave,
        cohort_rollout_transition: transition,
        event_type: "rollback",
        exposure_key: "incomplete-rollback:#{transition.id}:#{participant.user_id}",
        occurred_at: transition.occurred_at
      )
    end

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        rollout.reload
        CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
          operation_key: "cohort.rollout.rollback",
          operation_version: 2,
          input: {
            rollout_id: rollout.id,
            expected_status: rollout.status,
            expected_current_wave_position: rollout.current_wave_position,
            expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id),
            rollback_release_id: baseline.id
          },
          request_key: "incomplete-rollback-#{SecureRandom.hex(3)}"
        )
        connection.execute("SET CONSTRAINTS cohort_release_exposures_integrity_deferred IMMEDIATE")
      end
    end

    assert_match(/rollback must restore the captured baseline/, error.message)
    assert_equal "active", rollout.reload.status
    assert_equal participants.size, rollout.cohort_release_exposures.where(event_type: "wave").count
    assert_equal 0, rollout.cohort_release_exposures.where(event_type: "rollback").count
  ensure
    mutator_class&.define_method(:rollback!, original_rollback) if original_rollback
  end

  test "direct SQL cannot move rollback evidence onto another rollout wave" do
    owner, cohort, baseline, _target, _participants, rollout, _transition = advanced_rollout
    advance(owner, rollout.reload, "wrong-rollback-wave-second")
    force_runtime_constraints!
    defer_constraints!
    rollout.reload
    result = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.rollback",
      operation_version: 2,
      input: {
        rollout_id: rollout.id,
        expected_status: rollout.status,
        expected_current_wave_position: rollout.current_wave_position,
        expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id),
        rollback_release_id: baseline.id
      },
      request_key: "wrong-rollback-wave"
    )
    force_runtime_constraints!
    defer_constraints!
    exposure = result.transition.cohort_release_exposures.order(:id).first
    wrong_wave = rollout.waves.where.not(id: exposure.cohort_rollout_wave_id).first

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        connection.execute("ALTER TABLE cohort_release_exposures DISABLE TRIGGER cohort_release_exposures_immutable")
        connection.execute(<<~SQL)
          UPDATE cohort_release_exposures
          SET cohort_rollout_wave_id = #{wrong_wave.id}
          WHERE id = #{exposure.id}
        SQL
        connection.select_value("SELECT validate_cohort_rollout_transition_integrity(#{result.transition.id})")
      end
    end

    assert_match(/rollback must restore the captured baseline/, error.message)
    assert_equal exposure.cohort_rollout_wave_id, exposure.reload.cohort_rollout_wave_id
  end

  test "direct SQL cannot give rollout activation evidence a different actor role or timestamp" do
    owner = persona_user
    cohort = create_cohort(owner)
    baseline = seal_current_bundle(cohort, "actor-baseline")
    CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    force_runtime_constraints!
    defer_constraints!
    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    target = seal_current_bundle(cohort, "actor-target")
    rollout = plan_rollout(owner, cohort, target, [ participant ])
    force_runtime_constraints!
    defer_constraints!
    advance(owner, rollout, "actor-wave")
    force_runtime_constraints!
    defer_constraints!
    completion = advance(owner, rollout.reload, "actor-completion")
    force_runtime_constraints!
    defer_constraints!

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        connection.execute("ALTER TABLE cohorts DISABLE TRIGGER cohort_active_release_change_integrity_deferred")
        connection.execute("UPDATE cohorts SET active_cohort_release_id = #{baseline.id} WHERE id = #{cohort.id}")
        insert_activation_event(
          cohort: cohort,
          from_release_id: baseline.id,
          to_release_id: target.id,
          event_type: "rollout_completed",
          request_key: "mismatched-actor-time",
          rollout_id: rollout.id,
          transition_id: completion.transition.id,
          actor_user_id: owner.id,
          actor_role_snapshot: "reviewer",
          occurred_at: completion.transition.occurred_at + 1.second
        )
      end
    end

    assert_match(/must match its completed transition and release change/, error.message)
    assert_equal target.id, cohort.reload.active_cohort_release_id
  end

  private

  attr_reader :connection

  def setup
    @connection = ApplicationRecord.connection
  end

  def create_cohort(owner)
    Cohort.create!(
      name: "Runtime DB #{SecureRandom.hex(5)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: CoachWorkspaces::Provisioner.ensure_for!(owner)
    )
  end

  def seal_current_bundle(cohort, key)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
      request_key: key,
      expected_bundle_digest: candidate.bundle_digest
    )
  end

  def advanced_rollout
    owner = persona_user
    cohort = create_cohort(owner)
    baseline = seal_current_bundle(cohort, "sql-baseline-#{SecureRandom.hex(3)}")
    CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    force_runtime_constraints!
    defer_constraints!
    participants = 2.times.map do |index|
      user = persona_user(role: "participant", email: "db-runtime-#{index}-#{SecureRandom.hex(4)}@example.com")
      cohort.cohort_memberships.create!(user: user, role: "participant")
      user
    end
    target = seal_current_bundle(cohort, "sql-target-#{SecureRandom.hex(3)}")
    rollout = plan_rollout(owner, cohort, target, participants)
    force_runtime_constraints!
    defer_constraints!
    result = advance(owner, rollout, "sql-wave-#{SecureRandom.hex(3)}")
    force_runtime_constraints!
    defer_constraints!
    [ owner, cohort, baseline, target, participants, rollout, result.transition ]
  end

  def plan_rollout(owner, cohort, target, participants)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan",
      operation_version: 2,
      input: {
        target_release_id: target.id,
        expected_latest_release_id: target.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: participants.each_with_index.map { |user, index| { name: "Wave #{index + 1}", user_ids: [ user.id ] } }
      },
      request_key: "db-plan-#{SecureRandom.hex(5)}"
    ).rollout
  end

  def advance(owner, rollout, key)
    rollout.reload
    CoachOperations::Runner.new(cohort: rollout.cohort, actor: owner).call!(
      operation_key: "cohort.rollout.advance",
      operation_version: 2,
      input: {
        rollout_id: rollout.id,
        expected_status: rollout.status,
        expected_current_wave_position: rollout.current_wave_position,
        expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id),
        readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout)
      },
      request_key: key
    )
  end

  def insert_activation_event(cohort:, from_release_id:, to_release_id:, event_type:, request_key:,
    rollout_id: nil, transition_id: nil, actor_user_id: nil, actor_role_snapshot: nil, occurred_at: Time.current)
    connection.execute(<<~SQL)
      INSERT INTO cohort_release_activation_events
        (coach_workspace_id, cohort_id, from_cohort_release_id, to_cohort_release_id,
         cohort_rollout_id, cohort_rollout_transition_id, actor_user_id, actor_role_snapshot,
         event_type, request_key, request_fingerprint, database_transaction_id, occurred_at, created_at, updated_at)
      VALUES
        (#{cohort.coach_workspace_id}, #{cohort.id}, #{sql_value(from_release_id)}, #{to_release_id},
         #{sql_value(rollout_id)}, #{sql_value(transition_id)}, #{sql_value(actor_user_id)},
         #{sql_value(actor_role_snapshot)}, #{connection.quote(event_type)}, #{connection.quote(request_key)},
         #{connection.quote("a" * 64)}, 0, #{connection.quote(occurred_at)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_exposure(cohort:, rollout:, transition:, wave:, release:, participant:, membership_id:,
    membership_started_at:, key:)
    connection.execute(<<~SQL)
      INSERT INTO cohort_release_exposures
        (coach_workspace_id, cohort_id, user_id, cohort_membership_id, membership_started_at,
         cohort_release_id, cohort_rollout_id, cohort_rollout_wave_id, cohort_rollout_transition_id,
         event_type, exposure_key, occurred_at, created_at, updated_at)
      VALUES
        (#{cohort.coach_workspace_id}, #{cohort.id}, #{participant.id}, #{membership_id},
         #{connection.quote(membership_started_at)}, #{release.id}, #{rollout.id}, #{wave.id}, #{transition.id},
         'wave', #{connection.quote(key)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def sql_value(value)
    value.nil? ? "NULL" : connection.quote(value)
  end

  def force_runtime_constraints!
    connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
  end

  def defer_constraints!
    connection.execute("SET CONSTRAINTS ALL DEFERRED")
  end
end
