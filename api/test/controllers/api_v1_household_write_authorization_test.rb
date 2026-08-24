require "test_helper"

class ApiV1HouseholdWriteAuthorizationTest < ActionDispatch::IntegrationTest
  test "coach viewers can inspect the household but every financial mutation stays forbidden" do
    owner = create_user("viewer-owner@example.com")
    viewer = create_user("coach-viewer@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(owner).household
    household.household_memberships.create!(user: viewer, role: "coach_viewer")
    original_name = household.name

    [
      [ :get, "/api/v1/workspace" ],
      [ :get, "/api/v1/mia/messages" ],
      [ :get, "/api/v1/document_imports" ],
      [ :get, "/api/v1/plaid/items" ],
      [ :get, "/api/v1/plaid/transactions" ]
    ].each do |method, path|
      public_send(method, path, headers: auth_headers(viewer))
      assert_response :success, "expected #{method.upcase} #{path} to stay readable"
    end

    mutations = [
      [ :patch, "/api/v1/workspace/setup", { workspace: { household_name: "Unauthorized rename" } } ],
      [ :post, "/api/v1/budget_categories", { budget_category: { name: "Unauthorized", stack_key: "discretionary", monthly_amount: 10 } } ],
      [ :patch, "/api/v1/budget_allocations/999999", { budget_allocation: { amount: 10 } } ],
      [ :post, "/api/v1/income_schedule_entries", { income_schedule_entry: { income_source_id: 999999, amount: 10 } } ],
      [ :post, "/api/v1/mia/messages", { message: "Change groceries to $10" } ],
      [ :delete, "/api/v1/mia/messages", {} ],
      [ :post, "/api/v1/mia/transcriptions", {} ],
      [ :post, "/api/v1/mia_action_drafts/999999/apply", {} ],
      [ :patch, "/api/v1/transaction_drafts/999999", { transaction_draft: { merchant: "Unauthorized" } } ],
      [ :post, "/api/v1/transaction_drafts/bulk_ignore", { transaction_draft_ids: [ 999999 ] } ],
      [ :post, "/api/v1/document_imports", {} ],
      [ :post, "/api/v1/document_imports/999999/reprocess", {} ],
      [ :patch, "/api/v1/document_imports/999999/items/999999", { item: { selected: true } } ],
      [ :post, "/api/v1/plaid/items/link_token", { consent_accepted: true } ],
      [ :patch, "/api/v1/plaid/items/999999", { auto_confirm_trusted_merchants: true } ],
      [ :post, "/api/v1/plaid/transactions/stage", { transaction_ids: [ 999999 ] } ]
    ]

    mutations.each do |method, path, params|
      public_send(method, path, params: params, headers: auth_headers(viewer), as: :json)
      assert_response :forbidden, "expected #{method.upcase} #{path} to be forbidden"
      assert_equal [ "This household is read-only for your account." ], JSON.parse(response.body).fetch("errors")
    end

    assert_equal original_name, household.reload.name
    assert_empty household.household_audit_events
    assert_empty household.chat_sessions
  end

  test "partners retain the same supervised financial write access as owners" do
    owner = create_user("partner-owner@example.com")
    partner = create_user("household-partner@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(owner).household
    household.household_memberships.create!(user: partner, role: "partner")

    patch "/api/v1/workspace/setup",
      params: { workspace: { household_name: "Partner-updated household" } },
      headers: auth_headers(partner),
      as: :json

    assert_response :success
    assert_equal "Partner-updated household", household.reload.name
    assert household.household_audit_events.exists?(event_type: "workspace.setup_saved", user: partner)
  end

  private

  def create_user(email)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
