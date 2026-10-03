# frozen_string_literal: true

require "test_helper"

class CohortRolloutTest < ActiveSupport::TestCase
  setup do
    @owner = create_user(role: "admin")
    @participant = create_user
    @cohort = Cohort.create!(
      name: "Rollout foundation #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: @owner
    )
    @cohort.cohort_memberships.create!(user: @participant, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: @cohort.id)).call
    @release = @cohort.cohort_releases.sole
    @rollout = create_rollout
    @wave = @rollout.waves.create!(position: 1, name: "First households")
  end

  test "records a tenant-scoped immutable plan and ordered roster" do
    roster = @rollout.participants.create!(cohort_rollout_wave: @wave, user: @participant)

    assert_equal @cohort, @rollout.cohort
    assert_equal @cohort.coach_workspace, @rollout.coach_workspace
    assert_equal @release, @rollout.target_cohort_release
    assert_equal @cohort.id, @wave.cohort_id
    assert_equal @cohort.coach_workspace_id, roster.coach_workspace_id
    assert_equal 25, CohortRollout::MAX_WAVES
    assert_equal 500, CohortRollout::MAX_PARTICIPANTS
  end

  test "allows lifecycle state changes while rejecting plan identity changes" do
    @rollout.update!(status: "active", current_wave_position: 1, activated_at: Time.current)

    assert_equal "active", @rollout.reload.status
    assert_equal 1, @rollout.current_wave_position

    @rollout.target_cohort_release = nil
    assert_not @rollout.valid?
    assert_includes @rollout.errors[:base], "cohort rollout plan identity is immutable"
  end

  test "database triggers preserve plan identity and immutable child evidence" do
    participant = @rollout.participants.create!(cohort_rollout_wave: @wave, user: @participant)
    transition = create_transition

    assert_database_rejects do
      CohortRollout.connection.execute(
        "UPDATE cohort_rollouts SET planned_at = NOW() + INTERVAL '1 hour' WHERE id = #{@rollout.id}"
      )
    end
    assert_database_rejects do
      CohortRolloutWave.connection.execute(
        "UPDATE cohort_rollout_waves SET name = 'Changed' WHERE id = #{@wave.id}"
      )
    end
    assert_database_rejects do
      CohortRolloutParticipant.connection.execute(
        "DELETE FROM cohort_rollout_participants WHERE id = #{participant.id}"
      )
    end
    assert_database_rejects do
      CohortRolloutTransition.connection.execute(
        "UPDATE cohort_rollout_transitions SET occurred_at = NOW() WHERE id = #{transition.id}"
      )
    end
  end

  test "permits only one open rollout per cohort" do
    duplicate = build_rollout

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:cohort_id], "already has an open rollout plan"

    @rollout.update!(status: "cancelled", cancelled_at: Time.current)
    assert duplicate.save!
  end

  test "prevents closing a cohort while a rollout is open" do
    @cohort.status = "completed"

    assert_not @cohort.valid?
    assert_includes @cohort.errors[:status],
      "cannot be completed or archived while a rollout is planned, active, or paused"

    assert_database_rejects do
      Cohort.connection.execute("UPDATE cohorts SET status = 'archived' WHERE id = #{@cohort.id}")
    end
  end

  test "allows cohort closure after the rollout is no longer open" do
    @rollout.update!(status: "cancelled", cancelled_at: Time.current)

    @cohort.update!(status: "completed")

    assert_equal "completed", @cohort.reload.status
  end

  test "rejects opening a rollout after the cohort is already closed" do
    @rollout.update!(status: "cancelled", cancelled_at: Time.current)
    @cohort.update!(status: "archived")

    assert_database_rejects { build_rollout.save! }
  end

  test "can cancel a planned rollout when legacy data already closed the cohort" do
    Cohort.connection.execute("ALTER TABLE cohorts DISABLE TRIGGER cohorts_open_rollout_lifecycle_guard")
    Cohort.where(id: @cohort.id).update_all(status: "completed")
  ensure
    Cohort.connection.execute("ALTER TABLE cohorts ENABLE TRIGGER cohorts_open_rollout_lifecycle_guard")
    @rollout.update!(status: "cancelled", cancelled_at: Time.current)
    assert_equal "cancelled", @rollout.reload.status
  end

  test "roster evidence survives cohort membership removal" do
    roster = @rollout.participants.create!(cohort_rollout_wave: @wave, user: @participant)

    @cohort.cohort_memberships.find_by!(user: @participant).destroy!

    assert_equal @participant, roster.reload.user
    assert_not @cohort.cohort_memberships.exists?(user: @participant)
  end

  test "rejects cross-tenant release and wave lineage" do
    other_owner = create_user(role: "admin")
    other_cohort = Cohort.create!(
      name: "Outside rollout #{SecureRandom.hex(4)}",
      status: "enrolling",
      created_by_user: other_owner
    )
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: other_cohort.id)).call
    other_release = other_cohort.cohort_releases.sole

    invalid = build_rollout(target_cohort_release: other_release)

    assert_not invalid.valid?
    assert_includes invalid.errors[:target_cohort_release], "must belong to the rollout cohort and workspace"

    participant = @rollout.participants.build(cohort_rollout_wave: @wave, user: @participant)
    participant.cohort_id = other_cohort.id
    assert_not participant.valid?
    assert_includes participant.errors[:cohort_rollout], "must match the participant cohort and workspace"
  end

  test "bounds waves and current progress to the immutable plan" do
    too_late = @rollout.waves.build(position: CohortRollout::MAX_WAVES + 1, name: "Too late")
    assert_not too_late.valid?

    @rollout.current_wave_position = 2
    assert_not @rollout.valid?
    assert_includes @rollout.errors[:current_wave_position], "must reference a planned wave"
  end

  test "transition history always records that participant runtime stayed unchanged" do
    transition = create_transition

    assert_not transition.participant_runtime_changed
    transition.participant_runtime_changed = true
    assert_not transition.valid?
    assert_includes transition.errors[:participant_runtime_changed], "is not included in the list"
  end

  test "rejects illegal event-specific transition shapes before persistence" do
    transition = @rollout.transitions.build(
      actor_user: @owner,
      actor_role_snapshot: "platform_admin",
      event_type: "activated",
      from_status: "planned",
      to_status: "active",
      from_wave_position: 0,
      to_wave_position: 2,
      readiness_digest: "a" * 64,
      participant_runtime_changed: false,
      occurred_at: Time.current
    )

    assert_not transition.valid?
    assert_includes transition.errors[:base], "rollout transition does not match the legal event shape"

    attributes = transition.attributes.except("id", "created_at", "updated_at")
    assert_database_rejects { CohortRolloutTransition.insert_all!([ attributes ]) }
  end

  test "planned transition attribution must match the immutable planner" do
    other_actor = create_user(role: "admin")
    transition = @rollout.transitions.build(
      actor_user: other_actor,
      actor_role_snapshot: "platform_admin",
      event_type: "planned",
      from_status: nil,
      to_status: "planned",
      from_wave_position: nil,
      to_wave_position: 0,
      participant_runtime_changed: false,
      occurred_at: @rollout.planned_at
    )

    assert_not transition.valid?
    assert_includes transition.errors[:actor_user], "must match the rollout planner"
  end

  test "waves and participants cannot be appended after the planned transition" do
    create_transition
    late_wave = @rollout.waves.build(position: 2, name: "Late wave")
    late_participant = @rollout.participants.build(cohort_rollout_wave: @wave, user: create_user)

    assert_not late_wave.valid?
    assert_includes late_wave.errors[:base], "cannot append waves after rollout planning completes"
    assert_not late_participant.valid?
    assert_includes late_participant.errors[:base], "cannot append participants after rollout planning completes"

    now = Time.current
    assert_database_rejects do
      CohortRolloutWave.insert_all!([ {
        cohort_rollout_id: @rollout.id,
        cohort_id: @cohort.id,
        coach_workspace_id: @cohort.coach_workspace_id,
        position: 2,
        name: "Raw late wave",
        created_at: now,
        updated_at: now
      } ])
    end
  end

  test "rollback release must predate the rollout target" do
    @rollout.assign_attributes(
      status: "rolled_back",
      current_wave_position: 1,
      activated_at: Time.current,
      rolled_back_at: Time.current,
      rollback_cohort_release: @release
    )

    assert_not @rollout.valid?
    assert_includes @rollout.errors[:rollback_cohort_release], "must predate the target release"

    transition = @rollout.transitions.build(
      actor_user: @owner,
      actor_role_snapshot: "platform_admin",
      event_type: "rolled_back",
      from_status: "active",
      to_status: "rolled_back",
      from_wave_position: 1,
      to_wave_position: 1,
      rollback_cohort_release: @release,
      participant_runtime_changed: false,
      occurred_at: Time.current
    )
    assert_not transition.valid?
    assert_includes transition.errors[:rollback_cohort_release], "must predate the rollout target release"
  end

  private

  def create_user(role: "participant")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end

  def build_rollout(target_cohort_release: @release)
    CohortRollout.new(
      cohort: @cohort,
      coach_workspace: @cohort.coach_workspace,
      target_cohort_release: target_cohort_release,
      planned_by_user: @owner,
      planned_by_role_snapshot: "platform_admin",
      status: "planned",
      current_wave_position: 0,
      planned_at: Time.current
    )
  end

  def create_rollout
    rollout = build_rollout
    rollout.save!
    rollout
  end

  def create_transition
    @rollout.transitions.create!(
      actor_user: @owner,
      actor_role_snapshot: "platform_admin",
      event_type: "planned",
      from_status: nil,
      to_status: "planned",
      from_wave_position: nil,
      to_wave_position: 0,
      participant_runtime_changed: false,
      occurred_at: @rollout.planned_at
    )
  end

  def assert_database_rejects(&block)
    assert_raises(ActiveRecord::StatementInvalid) do
      CohortRollout.transaction(requires_new: true, &block)
    end
  end
end
