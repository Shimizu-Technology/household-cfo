require "test_helper"

class ApiV1FinanceScenariosTest < ActionDispatch::IntegrationTest
  test "scenario inputs validate before computation and cannot write financial records" do
    user = User.create!(clerk_id: "talun-scenarios", email: "talun-scenarios@example.test", role: "participant", invitation_status: "accepted")
    headers = { "Authorization" => "Bearer test_token_#{user.id}" }
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    original = household.attributes
    get "/api/v1/optionality", params: { scenario: "1", savings_cents: 6_000_000, monthly_costs_cents: 400_000, replacement_income_cents: 100_000 }, headers: headers
    assert_response :success
    assert_equal 20, response.parsed_body["months"]
    assert_equal 300_000, response.parsed_body["monthly_draw_cents"]
    get "/api/v1/cfo-filter", params: { scenario: "1", spend_cents: -1 }, headers: headers
    assert_response :bad_request
    get "/api/v1/optionality", params: { scenario: "1", savings_cents: "99999999999999999999999" }, headers: headers
    assert_response :bad_request
    get "/api/v1/cfo-filter", params: { scenario: "1", spend_cents: 0 }, headers: headers
    assert_response :success
    assert_nil response.parsed_body["base_surplus_cents"]
    assert_equal original, household.reload.attributes
    assert_equal 0, household.accounts.count
    assert_equal 0, household.income_sources.count
    assert_equal 0, household.budget_years.count
  end
end
