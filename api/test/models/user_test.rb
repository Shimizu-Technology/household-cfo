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

  test "db seed does not undo explicit default admin role or status changes" do
    user = User.create!(
      clerk_id: "pending_seeded_owner",
      email: "shimizutechnology@gmail.com",
      role: "participant",
      invitation_status: "revoked"
    )

    without_extra_seed_admins do
      capture_io { load Rails.root.join("db/seeds.rb") }
    end

    assert_equal "participant", user.reload.role
    assert_equal "revoked", user.invitation_status
  end

  private

  def without_extra_seed_admins
    previous_single = ENV.fetch("SEED_ADMIN_EMAIL", nil)
    previous_many = ENV.fetch("SEED_ADMIN_EMAILS", nil)
    ENV.delete("SEED_ADMIN_EMAIL")
    ENV.delete("SEED_ADMIN_EMAILS")
    yield
  ensure
    previous_single.nil? ? ENV.delete("SEED_ADMIN_EMAIL") : ENV["SEED_ADMIN_EMAIL"] = previous_single
    previous_many.nil? ? ENV.delete("SEED_ADMIN_EMAILS") : ENV["SEED_ADMIN_EMAILS"] = previous_many
  end
end
