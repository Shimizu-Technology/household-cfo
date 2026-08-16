require "test_helper"

class PlaidStaleItemRecoveryJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(clerk_id: "recovery_#{SecureRandom.hex(6)}", email: "plaid-recovery@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "queues only stale active items" do
    stale = create_item("stale", status: "active", last_successful_update_at: 2.days.ago)
    create_item("fresh", status: "active", last_successful_update_at: 1.hour.ago)
    create_item("repair", status: "update_required", last_successful_update_at: 2.days.ago)
    initializing = create_item("initializing", status: "active", last_successful_update_at: nil)

    assert_enqueued_jobs 1, only: PlaidTransactionSyncJob do
      PlaidStaleItemRecoveryJob.perform_now
    end
    assert_enqueued_with(job: PlaidTransactionSyncJob, args: [ stale.id ])
  end

  private

  def create_item(suffix, status:, last_successful_update_at:)
    @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "recovery-item-#{suffix}",
      access_token: "recovery-token-#{suffix}",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      status: status,
      consented_at: Time.current,
      consent_policy_version: "test",
      last_successful_update_at: last_successful_update_at
    )
  end
end
