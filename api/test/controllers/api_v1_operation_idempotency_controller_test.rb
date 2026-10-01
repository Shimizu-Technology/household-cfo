require "test_helper"

class ApiV1OperationIdempotencyControllerTest < ActionDispatch::IntegrationTest
  test "manual budget endpoints return the original success and reject key reuse with different input" do
    user = create_user
    headers = auth_headers(user).merge("Idempotency-Key" => "manual-create")

    post "/api/v1/budget_categories",
      params: { category: { name: "Dining", stack_key: "discretionary", monthly_amount: 250 } },
      headers: headers,
      as: :json
    assert_response :created
    original_id = response.parsed_body.dig("category", "id")

    post "/api/v1/budget_categories",
      params: { category: { name: "Dining", stack_key: "discretionary", monthly_amount: 250 } },
      headers: headers,
      as: :json
    assert_response :created
    assert_equal original_id, response.parsed_body.dig("category", "id")

    post "/api/v1/budget_categories",
      params: { category: { name: "Travel", stack_key: "discretionary", monthly_amount: 250 } },
      headers: headers,
      as: :json
    assert_response :conflict
    assert_includes response.parsed_body.fetch("errors").join, "different household change"
    refute user.households.first.budget_categories.exists?(name: "Travel")
  end

  test "duplicate Mia apply returns success without another mutation audit or chat message" do
    user = create_user
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    category = HouseholdFinance::AnnualBudgetManager.new(household).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)

    post "/api/v1/mia/messages",
      params: { year: Date.current.year, month: 8, message: "Set Groceries to $650 for August" },
      headers: auth_headers(user),
      as: :json
    assert_response :created
    draft_id = response.parsed_body.dig("mia_action_draft", "id")

    post "/api/v1/mia_action_drafts/#{draft_id}/apply", headers: auth_headers(user), as: :json
    assert_response :success
    counts = [ household.chat_sessions.find_by!(user: user).chat_messages.count, household.household_audit_events.count, household.household_operation_executions.count ]
    applied_at = MiaActionDraft.find(draft_id).applied_at

    post "/api/v1/mia_action_drafts/#{draft_id}/apply", headers: auth_headers(user), as: :json
    assert_response :success
    assert_equal counts, [ household.chat_sessions.find_by!(user: user).chat_messages.count, household.household_audit_events.count, household.household_operation_executions.count ]
    assert_equal applied_at, MiaActionDraft.find(draft_id).applied_at
    assert_equal 65_000, category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(Date.current.year, 8, 1) }).planned_amount_cents
  end

  test "manual allocation endpoint preserves archived-category editability" do
    user = create_user
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    category = manager.create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 250)
    allocation = category.budget_allocations.joins(:budget_period)
      .find_by!(budget_periods: { starts_on: Date.new(2026, 8, 1) })
    manager.archive_category!(category)

    patch "/api/v1/budget_allocations/#{allocation.id}",
      params: { allocation: { planned_amount: 325 } },
      headers: auth_headers(user).merge("Idempotency-Key" => "archived-allocation-api"),
      as: :json

    assert_response :success
    assert_equal 325.0, response.parsed_body.dig("allocation", "planned")
    assert_equal 32_500, allocation.reload.planned_amount_cents
  end

  private

  def create_user
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: "operation-controller-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
