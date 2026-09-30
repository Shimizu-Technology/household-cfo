require "test_helper"

class MiaEffectiveCohortResolverTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "cohort-resolver-#{SecureRandom.hex(6)}",
      email: "cohort-resolver-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @creator = User.create!(
      clerk_id: "cohort-creator-#{SecureRandom.hex(6)}",
      email: "cohort-creator-#{SecureRandom.hex(6)}@example.com",
      role: "admin",
      invitation_status: "accepted"
    )
  end

  test "prefers an active cohort over a later enrolling cohort" do
    draft = create_cohort("Draft cohort", "draft", Date.new(2027, 1, 1))
    older_active = create_cohort("Older active cohort", "active", Date.new(2026, 6, 1))
    newer_enrolling = create_cohort("Newer enrolling cohort", "enrolling", Date.new(2026, 9, 1))
    add_membership(draft)
    add_membership(older_active)
    add_membership(newer_enrolling)

    assert_equal older_active, Mia::EffectiveCohortResolver.new(user: @user).call.cohort
  end

  test "uses the latest membership when no active cohort exists" do
    first = create_cohort("First completed cohort", "completed", Date.new(2025, 1, 1))
    latest = create_cohort("Latest draft cohort", "draft", Date.new(2027, 1, 1))
    add_membership(first, created_at: 2.days.ago)
    expected = add_membership(latest, created_at: 1.day.ago)

    assert_equal expected, Mia::EffectiveCohortResolver.new(user: @user).call
  end

  test "returns nil without a user or membership" do
    assert_nil Mia::EffectiveCohortResolver.new(user: nil).call
    assert_nil Mia::EffectiveCohortResolver.new(user: @user).call
  end

  private

  def create_cohort(name, status, starts_on)
    Cohort.create!(name: name, status: status, starts_on: starts_on, created_by_user: @creator)
  end

  def add_membership(cohort, created_at: Time.current)
    CohortMembership.create!(cohort: cohort, user: @user, role: "participant", created_at: created_at, updated_at: created_at)
  end
end
