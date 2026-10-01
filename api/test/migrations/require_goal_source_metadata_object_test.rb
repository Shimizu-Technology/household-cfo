require "test_helper"

class RequireGoalSourceMetadataObjectTest < ActiveSupport::TestCase
  test "database rejects non-object goal source metadata" do
    user = User.create!(
      clerk_id: "goal_metadata_#{SecureRandom.hex(8)}",
      email: "goal-metadata-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    goal = household.goals.create!(label: "Family trip", goal_type: "travel")

    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        Goal.where(id: goal.id).update_all(source_metadata: [])
      end
    end
    assert_equal({}, goal.reload.source_metadata)
  end
end
