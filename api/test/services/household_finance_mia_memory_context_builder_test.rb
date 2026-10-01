require "test_helper"

class HouseholdFinanceMiaMemoryContextBuilderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "memory-context-#{SecureRandom.hex(4)}", email: "memory-context-#{SecureRandom.hex(4)}@example.com", role: "participant")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "context includes only bounded confirmed visible unexpired memories" do
    22.times do |index|
      create_memory("Preference #{index}", visibility: "private", status: "user_confirmed")
    end
    create_memory("Waiting", visibility: "private", status: "pending_confirmation")
    create_memory("Expired", visibility: "private", status: "user_confirmed", expires_at: 1.minute.ago)

    context = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call

    assert_equal "user_curated_personalization", context.fetch(:context_type)
    assert_equal 20, context.fetch(:memories).length
    assert_not context.fetch(:paused)
    assert_not_includes context.fetch(:memories).pluck(:value), "Waiting"
    assert_not_includes context.fetch(:memories).pluck(:value), "Expired"
    assert_includes context.fetch(:rule), "never financial truth"
  end

  test "private entries from another participant do not enter context" do
    partner = User.create!(clerk_id: "memory-partner-#{SecureRandom.hex(4)}", email: "memory-partner-#{SecureRandom.hex(4)}@example.com", role: "participant")
    @household.household_memberships.create!(user: partner, role: "partner")
    create_memory("Shared", visibility: "household", status: "user_confirmed", owner: partner)
    create_memory("Partner private", visibility: "private", status: "user_confirmed", owner: partner)

    values = HouseholdFinance::MiaMemoryContextBuilder.new(@household, user: @user).call.fetch(:memories).pluck(:value)
    assert_includes values, "Shared"
    assert_not_includes values, "Partner private"
  end

  private

  def create_memory(value, visibility:, status:, expires_at: nil, owner: @user)
    @household.household_memories.create!(
      owner_user: owner, category: "preference", status: status, sensitivity: "ordinary",
      visibility: visibility, source_kind: "manual_profile", display_value: value,
      confirmed_at: status == "user_confirmed" ? Time.current : nil, expires_at: expires_at
    )
  end
end
