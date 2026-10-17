require "test_helper"

# Manual QA found that amounts above the 32-bit cents columns ($21,474,836.47)
# crashed with a 500 while setup, accounts and debts accepted larger values.
# Every participant money input now shares one plain-language household limit.
class ApiV1AmountLimitsTest < ActionDispatch::IntegrationTest
  LIMIT_COPY = "$9,999,999.99 or less".freeze

  setup do
    @user = create_user(email: "amount-limits@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "budget categories and allocations reject amounts over the household limit with a 422" do
    post "/api/v1/budget_categories", params: { category: { name: "Huge", stack_key: "discretionary", monthly_amount: 30_000_000 } }, headers: headers, as: :json
    assert_limit_error "Planned amount"

    post "/api/v1/budget_categories", params: { category: { name: "Dining out", stack_key: "discretionary", monthly_amount: 250 } }, headers: headers, as: :json
    assert_response :created
    row = response.parsed_body.dig("budget", "annual_plan", "rows").find { |candidate| candidate.fetch("name") == "Dining out" }
    allocation_id = row.fetch("months").first.fetch("allocation_id")

    patch "/api/v1/budget_allocations/#{allocation_id}", params: { allocation: { planned_amount: "21474836.48" } }, headers: headers, as: :json
    assert_limit_error "Planned amount"
  end

  test "the household limit itself is accepted" do
    post "/api/v1/budget_categories", params: { category: { name: "Big but fine", stack_key: "discretionary", monthly_amount: "9999999.99" } }, headers: headers, as: :json
    assert_response :created
  end

  test "transaction drafts reject amounts over the household limit" do
    post "/api/v1/transaction_drafts", params: { transaction_draft: { occurred_on: Date.current.iso8601, merchant: "Big", amount: "30000000" } }, headers: headers, as: :json
    assert_limit_error "Transaction amount"
  end

  test "goals reject amounts over the household limit" do
    post "/api/v1/goals", params: { goal: { label: "Big goal", goal_type: "savings", target_amount: 30_000_000, current_amount: 0 } }, headers: headers, as: :json
    assert_limit_error "Target amount"
  end

  test "income sources reject amounts over the household limit" do
    post "/api/v1/income_sources?year=#{Date.current.year}", params: { income_source: { label: "Big income", source_type: "other", amount: "30000000", cadence: "monthly", starts_on: Date.current.beginning_of_month.iso8601 } }, headers: headers, as: :json
    assert_limit_error "Income amount"
  end

  test "accounts and debts use the same household limit" do
    post "/api/v1/accounts", params: { account: { label: "Big account", account_type: "savings", balance: 30_000_000 } }, headers: headers, as: :json
    assert_limit_error "Balance"

    post "/api/v1/debts", params: { debt: { label: "Big debt", debt_type: "mortgage", balance: 30_000_000, minimum_payment: 10 } }, headers: headers, as: :json
    assert_limit_error "Balance"
  end

  test "setup names a too-large whole number plainly instead of a decimal-places error" do
    patch "/api/v1/workspace/setup", params: { workspace: { fixed_expenses: "999999999999999" } }, headers: headers, as: :json
    assert_limit_error "Fixed essentials"
    refute_includes response.parsed_body.fetch("errors").join, "decimal places"
  end

  test "document rows above the household limit are left out with a plain warning" do
    data = { "items" => [
      { "target_type" => "expense_item", "label" => "Huge", "amount" => "25,000,000.00" },
      { "target_type" => "expense_item", "label" => "Rent", "amount" => "1500.00" }
    ] }
    import = FinancialDocumentImport.new(document_kind: "other")
    result = FinancialDocuments::Extractor.new.send(:normalize_extraction, data, import)

    assert_equal [ "Rent" ], result.fetch(:items).map { |item| item.fetch(:label) }
    assert_includes result.fetch(:warnings).join, "above $9,999,999.99"
  end

  test "a debt row with an over-limit balance is dropped even when its payment is valid" do
    data = { "items" => [
      { "target_type" => "debt", "label" => "Huge card", "balance" => "25,000,000.00", "payment" => "200.00" },
      { "target_type" => "debt", "label" => "Visa", "balance" => "3400.00", "payment" => "175.00" }
    ] }
    result = FinancialDocuments::Extractor.new.send(:normalize_extraction, data, FinancialDocumentImport.new(document_kind: "other"))

    assert_equal [ "Visa" ], result.fetch(:items).map { |item| item.fetch(:label) }
    assert_includes result.fetch(:warnings).join, "above $9,999,999.99"
  end

  test "document import items cannot store out-of-range cents" do
    item = FinancialDocumentImportItem.new(target_type: "expense_item", label: "Huge", amount_cents: 2_500_000_000)
    assert_not item.valid?
    assert_includes item.errors.full_messages.join, LIMIT_COPY
  end

  test "an out-of-range cents value that bypasses parsing is still a 422, never a 500" do
    post "/api/v1/budget_categories", params: { category: { name: "Dining out", stack_key: "discretionary", monthly_amount: 250 } }, headers: headers, as: :json
    allocation = @household.budget_categories.find_by!(name: "Dining out").budget_allocations.first

    error = assert_raises(ActiveRecord::RecordInvalid) { allocation.update!(planned_amount_cents: 3_000_000_000) }
    assert_includes error.message, LIMIT_COPY
  end

  private

  def create_user(email:)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def headers
    { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }
  end

  def assert_limit_error(label)
    assert_response :unprocessable_entity
    message = response.parsed_body.fetch("errors").join(" ")
    assert_includes message, label
    assert_includes message, LIMIT_COPY
  end
end
