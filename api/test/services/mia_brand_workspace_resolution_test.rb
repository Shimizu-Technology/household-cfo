# frozen_string_literal: true

require "test_helper"

class MiaBrandWorkspaceResolutionTest < ActiveSupport::TestCase
  test "brand workspace constrains default and explicitly requested participant cohorts" do
    first_owner = create_user("coach")
    second_owner = create_user("coach")
    participant = create_user("participant")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    first_cohort = Cohort.create!(name: "First branded cohort", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    second_cohort = Cohort.create!(name: "Second branded cohort", status: "active", created_by_user: second_owner, coach_workspace: second_workspace)
    first_membership = first_cohort.cohort_memberships.create!(user: participant, role: "participant")
    second_cohort.cohort_memberships.create!(user: participant, role: "participant")

    resolved = Mia::EffectiveCohortResolver.new(
      user: participant,
      role: "participant",
      coach_workspace: first_workspace
    ).call
    assert_equal first_membership, resolved

    error = assert_raises(Mia::EffectiveCohortResolver::InvalidSelection) do
      Mia::EffectiveCohortResolver.new(
        user: participant,
        role: "participant",
        coach_workspace: first_workspace,
        requested_cohort_id: second_cohort.id
      ).call
    end
    assert_equal "The selected cohort is unavailable for this participant.", error.message
  end

  test "brand workspace leaves staff without a participant membership in the standalone runtime" do
    owner = create_user("coach")
    staff = create_user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Coach-only branded cohort", status: "active", created_by_user: owner, coach_workspace: workspace)
    cohort.cohort_memberships.create!(user: staff, role: "coach")

    assert_nil Mia::EffectiveCohortResolver.new(
      user: staff,
      role: "participant",
      coach_workspace: workspace
    ).call
  end

  private

  def create_user(role)
    User.create!(
      clerk_id: "brand_resolution_#{SecureRandom.hex(7)}",
      email: "brand-resolution-#{SecureRandom.hex(7)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end
end
