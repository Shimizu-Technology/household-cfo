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

  test "reclassifying a budget category updates the matching expense item instead of duplicating totals" do
    user = create_user(email: "annual-reclassify@example.com")

    post "/api/v1/budget_categories",
      params: { category: { name: "Dining out", stack_key: "discretionary", monthly_amount: 250 } },
      headers: auth_headers(user),
      as: :json
    assert_response :created

    post "/api/v1/budget_categories",
      params: { category: { name: "Dining out", stack_key: "non_discretionary", monthly_amount: 300 } },
      headers: auth_headers(user),
      as: :json

    assert_response :created
    household = user.households.first.reload
    active_expenses = household.expense_items.where(label: "Dining out", active: true)
    assert_equal 1, active_expenses.count
    assert_equal "non_discretionary", active_expenses.first.stack_key
    assert_equal 30_000, active_expenses.first.amount_cents

    budget = JSON.parse(response.body).fetch("budget")
    assert_equal 300, budget.fetch("total_monthly_outflow")
    row = budget.fetch("annual_plan").fetch("rows").find { |candidate| candidate.fetch("name") == "Dining out" }
    assert_equal "Non-discretionary", row.fetch("stack_label")
    assert_equal 300, row.fetch("months").first.fetch("planned")
  end

  test "allocation updates are scoped to the current household" do
    owner = create_user(email: "allocation-owner@example.com")
    other_user = create_user(email: "allocation-other@example.com")
    HouseholdFinance::WorkspaceResolver.new(other_user).household

    post "/api/v1/budget_categories",
      params: { category: { name: "Groceries", stack_key: "discretionary", monthly_amount: 500 } },
      headers: auth_headers(owner),
      as: :json

    assert_response :created
    row = JSON.parse(response.body).fetch("budget").fetch("annual_plan").fetch("rows").find { |candidate| candidate.fetch("name") == "Groceries" }
    allocation = BudgetAllocation.find(row.fetch("months").first.fetch("allocation_id"))

    patch "/api/v1/budget_allocations/#{allocation.id}",
      params: { allocation: { planned_amount: 1_000 } },
      headers: auth_headers(other_user),
      as: :json

    assert_response :not_found
    assert_equal 50_000, allocation.reload.planned_amount_cents
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

    assert_no_difference("HouseholdTransaction.count") do
      post "/api/v1/transaction_drafts/#{draft.fetch("id")}/confirm",
        headers: auth_headers(user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Transaction draft is not pending"

    post "/api/v1/transaction_drafts/#{draft.fetch("id")}/ignore",
      headers: auth_headers(user),
      as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Transaction draft is not pending"
    assert_equal "confirmed", TransactionDraft.find(draft.fetch("id")).status
  end

  test "confirming with a category from another household returns validation errors" do
    user = create_user(email: "foreign-category-draft@example.com")
    other_user = create_user(email: "foreign-category-other@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_category = HouseholdFinance::AnnualBudgetManager.new(other_household).create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 100)

    patch "/api/v1/workspace/setup",
      params: { workspace: { flexible_spend: 1_000 } },
      headers: auth_headers(user),
      as: :json

    post "/api/v1/mia/messages",
      params: { message: "I spent $25 at McDonald's today" },
      headers: auth_headers(user),
      as: :json

    draft_id = JSON.parse(response.body).fetch("transaction_draft").fetch("id")

    assert_no_difference("HouseholdTransaction.count") do
      post "/api/v1/transaction_drafts/#{draft_id}/confirm",
        params: { transaction_draft: { budget_category_id: other_category.id } },
        headers: auth_headers(user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Budget category not found"
    assert_equal "pending", TransactionDraft.find(draft_id).status
  end

  test "confirming with user corrections preserves corrected audit status" do
    user = create_user(email: "corrected-draft@example.com")
    patch "/api/v1/workspace/setup",
      params: { workspace: { flexible_spend: 1_000 } },
      headers: auth_headers(user),
      as: :json

    post "/api/v1/mia/messages",
      params: { message: "I spent $25 at McDonald's today" },
      headers: auth_headers(user),
      as: :json

    draft_id = JSON.parse(response.body).fetch("transaction_draft").fetch("id")

    post "/api/v1/transaction_drafts/#{draft_id}/confirm",
      params: { transaction_draft: { merchant: "McDonald's Dededo", amount: 30 } },
      headers: auth_headers(user),
      as: :json

    assert_response :success
    response_draft = JSON.parse(response.body).fetch("transaction_draft")
    assert_equal "corrected", response_draft.fetch("status")

    draft = TransactionDraft.find(draft_id)
    assert_equal "corrected", draft.status
    assert_equal "McDonald's Dededo", draft.confirmed_transaction.merchant
    assert_equal 3_000, draft.confirmed_transaction.total_amount_cents
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
