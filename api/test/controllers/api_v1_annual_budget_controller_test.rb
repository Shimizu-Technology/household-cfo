require "test_helper"

class ApiV1AnnualBudgetControllerTest < ActionDispatch::IntegrationTest
  test "workspace setup seeds the annual budget from expense stack values" do
    user = create_user(email: "annual-seed@example.com")

    patch "/api/v1/workspace/setup",
      params: {
        workspace: {
          primary_income: 8_000,
          fixed_expenses: 4_000,
          flexible_spend: 1_200,
          expected_sinking_fund: 300,
          unexpected_sinking_fund: 200
        }
      },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    annual_plan = JSON.parse(response.body).fetch("budget").fetch("annual_plan")
    assert_equal Date.current.year, annual_plan.fetch("year")
    assert_equal 12, annual_plan.fetch("months").length
    first_month_id = annual_plan.fetch("months").first.fetch("id").to_s
    assert_equal 8_000, annual_plan.fetch("monthly_income").fetch(first_month_id)

    fixed_row = annual_plan.fetch("rows").find { |row| row.fetch("name") == "Fixed essentials" }
    assert fixed_row.present?
    assert_equal 4_000, fixed_row.fetch("months").first.fetch("planned")
  end

  test "participant can add a budget category and edit a monthly allocation" do
    user = create_user(email: "annual-edit@example.com")
    HouseholdFinance::WorkspaceResolver.new(user).household

    post "/api/v1/budget_categories",
      params: { category: { name: "Dining out", stack_key: "discretionary", monthly_amount: 250 } },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    budget = JSON.parse(response.body).fetch("budget")
    row = budget.fetch("annual_plan").fetch("rows").find { |candidate| candidate.fetch("name") == "Dining out" }
    assert row.present?
    assert_equal 250, row.fetch("months").first.fetch("planned")

    allocation_id = row.fetch("months").first.fetch("allocation_id")
    patch "/api/v1/budget_allocations/#{allocation_id}",
      params: { allocation: { planned_amount: 325 } },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    refreshed_row = JSON.parse(response.body).fetch("budget").fetch("annual_plan").fetch("rows").find { |candidate| candidate.fetch("name") == "Dining out" }
    assert_equal 325, refreshed_row.fetch("months").first.fetch("planned")
  end

  test "Mia chat drafts a transaction and confirmation posts month-to-date actuals" do
    user = create_user(email: "transaction-loop@example.com")
    patch "/api/v1/workspace/setup",
      params: { workspace: { flexible_spend: 1_000 } },
      headers: auth_headers(user),
      as: :json

    assert_difference("TransactionDraft.count", 1) do
      post "/api/v1/mia/messages",
        params: { message: "I spent $25 at McDonald's today" },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    draft = body.fetch("transaction_draft")
    assert_equal "McDonald's", draft.fetch("merchant")
    assert_equal 25, draft.fetch("amount")
    assert_equal "Flexible spending", draft.fetch("category_name")

    assert_difference("HouseholdTransaction.count", 1) do
      post "/api/v1/transaction_drafts/#{draft.fetch("id")}/confirm",
        headers: auth_headers(user),
        as: :json
    end

    assert_response :success
    workspace = JSON.parse(response.body).fetch("workspace")
    annual_plan = workspace.fetch("budget").fetch("annual_plan")
    current_month_index = Date.current.month - 1
    row = annual_plan.fetch("rows").find { |candidate| candidate.fetch("name") == "Flexible spending" }
    assert_equal 25, row.fetch("months").fetch(current_month_index).fetch("actual")
    assert_empty annual_plan.fetch("pending_transaction_drafts")
  end

  private

  def create_user(email:)
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
