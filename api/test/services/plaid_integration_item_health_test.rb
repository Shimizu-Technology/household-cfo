require "test_helper"

class PlaidIntegrationItemHealthTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "health_#{SecureRandom.hex(6)}", email: "plaid-health@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "reports a recently updated active item as healthy" do
    item = create_item(last_successful_update_at: 2.hours.ago)

    health = PlaidIntegration::ItemHealth.new(item).as_json

    assert_equal "healthy", health.fetch(:state)
    refute health.fetch(:requires_attention)
  end

  test "reports active items beyond the freshness window as stale" do
    item = create_item(last_successful_update_at: 2.days.ago)

    health = PlaidIntegration::ItemHealth.new(item).as_json

    assert_equal "stale", health.fetch(:state)
    assert health.fetch(:requires_attention)
  end

  test "prioritizes reconnect state over freshness" do
    item = create_item(status: "update_required", last_successful_update_at: 2.days.ago)

    health = PlaidIntegration::ItemHealth.new(item).as_json

    assert_equal "action_required", health.fetch(:state)
    assert_equal "Reconnect needed", health.fetch(:label)
  end

  private

  def create_item(status: "active", last_successful_update_at: nil)
    @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "health-item-#{SecureRandom.hex(4)}",
      access_token: "health-token",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      status: status,
      consented_at: Time.current,
      consent_policy_version: "test",
      last_successful_update_at: last_successful_update_at
    )
  end
end
