# frozen_string_literal: true

require "test_helper"
require "timeout"

class CohortRolloutLifecycleConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "serializes rollout creation against concurrent cohort closure" do
    owner = create_owner
    cohort = Cohort.create!(
      name: "Concurrent rollout #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: owner
    )
    workspace = cohort.coach_workspace
    participant = create_participant
    CohortMembership.create!(cohort: cohort, user: participant, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    release = cohort.cohort_releases.sole
    plan_input = {
      "target_release_id" => release.id,
      "expected_latest_release_id" => release.id,
      "expected_roster_digest" => CohortRollouts::Contract.roster_digest(cohort),
      "waves" => [ { "name" => "First households", "user_ids" => [ participant.id ] } ]
    }
    cohort_locked = Queue.new
    closure_started = Queue.new
    closure_result = Queue.new

    inserter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Cohort.transaction do
          Cohort.lock.find(cohort.id)
          cohort_locked << true
          closure_started.pop
          CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
            operation_key: "cohort.rollout.plan",
            operation_version: 1,
            input: plan_input,
            request_key: "concurrent-rollout-plan"
          )
        end
      end
    end
    closer = Thread.new do
      cohort_locked.pop
      ActiveRecord::Base.connection_pool.with_connection do
        closure_started << true
        Cohort.where(id: cohort.id).update_all(status: "completed")
        closure_result << :closed
      rescue ActiveRecord::StatementInvalid => error
        closure_result << error
      end
    end

    Timeout.timeout(5) do
      inserter.join
      closer.join
    end

    assert_kind_of ActiveRecord::StatementInvalid, closure_result.pop
    assert_equal "enrolling", cohort.reload.status
    assert_equal 1, cohort.cohort_rollouts.count
  ensure
    inserter&.kill
    closer&.kill
    cleanup_rollout_records(cohort)
    cleanup_cohort_records(cohort, workspace)
    User.where(id: [ participant&.id, owner&.id ].compact).delete_all
  end

  test "concurrent participant role change becomes a stale plan without partial evidence" do
    owner, cohort, workspace, participant, release = rollout_components
    newcomer = create_participant
    changing_membership = CohortMembership.create!(cohort: cohort, user: newcomer, role: "coach")
    plan_built = Queue.new
    roster_changed = Queue.new
    planner_result = Queue.new

    operation_class = CoachOperations::CohortRolloutPlan
    original_execute = operation_class.instance_method(:execute!)
    operation_class.define_method(:execute!) do |prepared, request_key:|
      result = original_execute.bind_call(self, prepared, request_key: request_key)
      plan_built << true
      roster_changed.pop
      result
    end
    planner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        input = {
          "target_release_id" => release.id,
          "expected_latest_release_id" => release.id,
          "expected_roster_digest" => CohortRollouts::Contract.roster_digest(cohort),
          "waves" => [ { "name" => "First households", "user_ids" => [ participant.id ] } ]
        }
        result = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
          operation_key: "cohort.rollout.plan",
          operation_version: 1,
          input: input,
          request_key: "concurrent-roster-plan"
        )
        planner_result << result
      rescue StandardError => error
        planner_result << error
      end
    end

    Timeout.timeout(5) do
      plan_built.pop
      changing_membership.update!(role: "participant")
      roster_changed << true
      planner.join
    end

    error = planner_result.pop
    assert_kind_of CohortRollouts::StateMachine::Stale, error
    assert_equal "The participant roster changed; reload before planning.", error.message
    assert_empty cohort.cohort_rollouts
    assert_empty CohortRolloutTransition.where(cohort: cohort)
    assert_empty cohort.coach_operation_executions
  ensure
    operation_class&.define_method(:execute!, original_execute) if original_execute
    roster_changed << true if roster_changed&.empty?
    planner&.kill
    cleanup_rollout_records(cohort)
    cleanup_cohort_records(cohort, workspace)
    User.where(id: [ newcomer&.id, participant&.id, owner&.id ].compact).delete_all
  end

  test "participant added after a committed plan remains outside its immutable roster" do
    owner, cohort, workspace, participant, release = rollout_components
    input = {
      "target_release_id" => release.id,
      "expected_latest_release_id" => release.id,
      "expected_roster_digest" => CohortRollouts::Contract.roster_digest(cohort),
      "waves" => [ { "name" => "First households", "user_ids" => [ participant.id ] } ]
    }
    rollout = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan",
      operation_version: 1,
      input: input,
      request_key: "plan-before-roster-change"
    ).rollout

    newcomer = create_participant
    CohortMembership.create!(cohort: cohort, user: newcomer, role: "participant")

    assert_equal [ participant.id ], rollout.participants.pluck(:user_id)
    assert_equal [ participant.id, newcomer.id ].sort,
      cohort.cohort_memberships.where(role: "participant").pluck(:user_id).sort
  ensure
    cleanup_rollout_records(cohort)
    cleanup_cohort_records(cohort, workspace)
    User.where(id: [ newcomer&.id, participant&.id, owner&.id ].compact).delete_all
  end

  private

  def create_owner
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: "admin",
      invitation_status: "accepted"
    )
  end

  def create_participant
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def rollout_components
    owner = create_owner
    cohort = Cohort.create!(
      name: "Concurrent roster #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: owner
    )
    participant = create_participant
    CohortMembership.create!(cohort: cohort, user: participant, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    [ owner, cohort, cohort.coach_workspace, participant, cohort.cohort_releases.sole ]
  end

  def cleanup_rollout_records(cohort)
    return unless cohort

    triggers = {
      coach_operation_executions: "coach_operation_executions_immutable",
      cohort_rollout_transitions: "cohort_rollout_transitions_immutable",
      cohort_rollout_participants: "cohort_rollout_participants_immutable",
      cohort_rollout_waves: "cohort_rollout_waves_immutable",
      cohort_rollouts: "cohort_rollouts_protect_identity"
    }
    triggers.each { |table, trigger| disable_trigger(table, trigger) }
    CohortRollout.transaction do
      CoachOperationExecution.where(cohort_id: cohort.id).delete_all
      CohortRolloutTransition.where(cohort_id: cohort.id).delete_all
      CohortRolloutParticipant.where(cohort_id: cohort.id).delete_all
      CohortRolloutWave.where(cohort_id: cohort.id).delete_all
      CohortRollout.where(cohort_id: cohort.id).delete_all
    end
  ensure
    triggers&.each { |table, trigger| enable_trigger(table, trigger) }
  end

  def cleanup_cohort_records(cohort, workspace)
    return unless cohort

    CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
    CohortRelease.where(cohort_id: cohort.id).delete_all
    CohortMembership.where(cohort_id: cohort.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohort.id).delete_all
    Cohort.where(id: cohort.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
  ensure
    CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
  end


  def disable_trigger(table, trigger)
    ActiveRecord::Base.connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
  end

  def enable_trigger(table, trigger)
    ActiveRecord::Base.connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
  end
end
