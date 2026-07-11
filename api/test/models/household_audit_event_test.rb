require "test_helper"

class HouseholdAuditEventTest < ActiveSupport::TestCase
  test "accepts the database default empty metadata object" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "audit-event@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Audit Event Household")

    event = household.household_audit_events.new(
      user: user,
      actor_type: "user",
      event_type: "test.event",
      occurred_at: Time.current
    )

    assert event.valid?
    assert_equal({}, event.metadata)
  end

  test "rejects non-object metadata" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "audit-event-array@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Audit Event Array Household")
    event = household.household_audit_events.new(
      actor_type: "system",
      event_type: "test.event",
      occurred_at: Time.current,
      metadata: [ "not", "an", "object" ]
    )

    refute event.valid?
    assert_includes event.errors[:metadata], "must be an object"
  end
end
