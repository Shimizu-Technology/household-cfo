require "test_helper"

class ApiV1BillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "talun-bill-owner", email: "talun-bills@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @headers = { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  test "participant explicitly creates edits and removes a bill" do
    post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: "12.34", due_on: "2026-12-31", repeat_months: 12, must_pay: true } }, headers: @headers, as: :json
    assert_response :created
    bill = @household.bills.sole
    assert_equal 1234, bill.amount_cents
    patch "/api/v1/bills/#{bill.id}", params: { bill: { amount: "50", estimate: true } }, headers: @headers, as: :json
    assert_response :success
    assert_equal 5000, bill.reload.amount_cents
    assert bill.estimate?
    delete "/api/v1/bills/#{bill.id}", headers: @headers
    assert_response :success
    assert_empty @household.bills
  end

  test "reject another household category and invalid amounts" do
    other = Household.create!(name: "Invented neighbor", created_by_user: @user)
    category = other.budget_categories.create!(name: "Private fee", stack_key: "discretionary")
    assert_no_difference "Bill.count" do
      post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: 50, due_on: "2026-12-20", budget_category_id: category.id } }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    post "/api/v1/bills", params: { bill: { name: "Talun fee", amount: -1, due_on: "2026-12-20" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end
end
