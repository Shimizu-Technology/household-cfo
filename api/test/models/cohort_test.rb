require "test_helper"

class CohortTest < ActiveSupport::TestCase
  test "cohort validates status and date order" do
    admin = create_user(role: "admin")
    cohort = Cohort.new(
      name: "Tuesday Pilot",
      status: "active",
      starts_on: Date.new(2026, 6, 23),
      ends_on: Date.new(2026, 6, 22),
      created_by_user: admin
    )

    assert_not cohort.valid?
    assert_includes cohort.errors[:ends_on], "must be on or after starts on"

    cohort.ends_on = Date.new(2026, 7, 23)
    assert cohort.valid?
  end

  test "cohort memberships are unique per user and cohort" do
    admin = create_user(role: "admin")
    participant = create_user(email: "participant@example.com")
    cohort = Cohort.create!(name: "Q3 Pilot", status: "enrolling", created_by_user: admin)
    cohort.cohort_memberships.create!(user: participant, role: "participant")

    duplicate = cohort.cohort_memberships.build(user: participant, role: "participant")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  private

  def create_user(email: nil, role: "participant")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email || "#{SecureRandom.hex(6)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end
end
