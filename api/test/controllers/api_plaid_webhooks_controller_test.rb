require "test_helper"

class ApiPlaidWebhooksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    user = User.create!(clerk_id: "controller_webhook_#{SecureRandom.hex(6)}", email: "plaid-controller-webhook@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    @item = household.plaid_items.create!(
      connected_by_user: user,
      plaid_item_id: "controller-webhook-item",
      access_token: "controller-webhook-secret",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test"
    )
  end

  test "verified transaction notifications enqueue synchronization" do
    payload = { webhook_type: "TRANSACTIONS", webhook_code: "SYNC_UPDATES_AVAILABLE", item_id: @item.plaid_item_id }

    assert_enqueued_with(job: PlaidTransactionSyncJob, args: [ @item.id ]) do
      post_verified(payload)
    end

    assert_response :no_content
  end

  test "verified item notifications update connection health" do
    post_verified(webhook_type: "ITEM", webhook_code: "PENDING_DISCONNECT", item_id: @item.plaid_item_id)

    assert_response :no_content
    assert_equal "update_required", @item.reload.status
  end

  test "missing verification headers are rejected" do
    post "/api/plaid/webhook", params: { webhook_type: "TRANSACTIONS", item_id: @item.plaid_item_id }.to_json, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unauthorized
    assert_no_enqueued_jobs
  end

  private

  def post_verified(payload)
    verifier = Object.new
    verifier.define_singleton_method(:verify!) { true }
    singleton = class << PlaidIntegration::WebhookVerifier; self; end
    original = PlaidIntegration::WebhookVerifier.method(:new)
    singleton.define_method(:new) { |**_args| verifier }
    post "/api/plaid/webhook", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json", "Plaid-Verification" => "verified" }
  ensure
    singleton.define_method(:new, original) if singleton && original
  end
end
