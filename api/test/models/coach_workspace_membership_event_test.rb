require "test_helper"

class CoachWorkspaceMembershipEventTest < ActiveSupport::TestCase
  setup do
    @actor = User.create!(email: "event-owner-#{SecureRandom.hex(6)}@example.test", clerk_id: "event_owner_#{SecureRandom.hex(6)}", role: "coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@actor)
    @event = CoachWorkspaceMembershipEvent.create!(coach_workspace: @workspace, actor_user: @actor,
      subject_user: @actor, event_type: "added", after_role: "owner")
  end

  test "access evidence cannot be rewritten or deleted through SQL bypassing callbacks" do
    mutations = [
      -> { @event.update_columns(after_role: "viewer") },
      -> { CoachWorkspaceMembershipEvent.where(id: @event.id).update_all(actor_user_id: nil) },
      -> { CoachWorkspaceMembershipEvent.where(id: @event.id).delete_all }
    ]
    mutations.each do |mutation|
      assert_raises(ActiveRecord::StatementInvalid) do
        CoachWorkspaceMembershipEvent.transaction(requires_new: true) { mutation.call }
      end
      assert_equal "owner", @event.reload.after_role
      assert_equal @actor.id, @event.actor_user_id
    end
  end

  test "direct inserts reject unsupported roles but allow absent before or after roles" do
    row = @event.attributes.except("id")
    %w[before_role after_role].each do |column|
      assert_raises(ActiveRecord::StatementInvalid) do
        CoachWorkspaceMembershipEvent.transaction(requires_new: true) do
          CoachWorkspaceMembershipEvent.insert_all!([ row.merge(column => "platform_admin") ])
        end
      end
    end
    assert_difference "CoachWorkspaceMembershipEvent.count", 2 do
      CoachWorkspaceMembershipEvent.insert_all!([
        row.merge("before_role" => nil, "after_role" => "viewer"),
        row.merge("before_role" => "viewer", "after_role" => nil, "event_type" => "removed")
      ])
    end
  end
end
