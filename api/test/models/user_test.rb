require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email and exposes role helpers" do
    user = User.create!(
      clerk_id: "user_normalized",
      email: "  PARTICIPANT@example.COM ",
      role: "participant"
    )

    assert_equal "participant@example.com", user.email
    assert user.participant?
    assert_not user.staff?
    assert_equal "participant", user.full_name
  end

  test "pending invitations are detected from pending clerk id" do
    user = User.create!(
      clerk_id: "pending_123",
      email: "coach@example.com",
      role: "coach",
      invitation_status: "pending"
    )

    assert user.invitation_pending?
    assert user.staff?
  end
end
