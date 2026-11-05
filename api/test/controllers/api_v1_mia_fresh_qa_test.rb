require "test_helper"

class ApiV1MiaFreshQaTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    @user = User.create!(clerk_id: "fresh_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  test "M8 a miss stays in setup and a long name can be reviewed without truncation" do
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("$3,900")
    assert_includes reply, "What would you like to call this household?"
    refute_match(/readiness|safe.to.spend/, reply)
    name = "The Santos Cruz Dela Rosa extended family household of Dededo"
    post_message(name)
    draft = response.parsed_body.fetch("mia_action_draft")
    assert draft, reply
    item = draft.fetch("items").find { |entry| entry["action_type"] == "update_household_profile" }
    assert_equal name, item.dig("payload", "name")
  end

  test "M8 income question survives a miss and accepts natural language and bare amount" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz household", primary_goal: "Pay off Visa").call
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("I am not sure")
    assert_includes reply, "monthly take-home income"
    post_message("I take home about $4,800 a month from my job at the hospital")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert draft, reply
    assert_equal 0, @household.income_sources.count
    post_message("$4,800")
    assert response.parsed_body["mia_action_draft"], reply
    refute_match(/readiness color/, reply)
  end

  test "M3 no debt payments is a reviewed minimum of zero not an invented balance" do
    five_answers
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    assert_includes reply, "debt minimum"
    post_message("no debt payments")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert draft, reply
    refute HouseholdFinance::DebtPortfolio.new(@household.reload).minimum_payment_known?
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert HouseholdFinance::SetupStatus.new(@household.reload).complete?
    portfolio = HouseholdFinance::DebtPortfolio.new(@household)
    assert portfolio.minimum_payment_known?
    assert_equal 0, portfolio.monthly_minimum_cents
    refute portfolio.balance_known?
    assert_includes response.parsed_body.dig("workspace", "mia", "messages").last.fetch("content"), "setup is complete"
    assert_equal 150000, response.parsed_body.dig("workspace", "dashboard", "month_answer", "plan_left_cents")
  end

  test "M3 month answer persists direct links to the actual missing numbers" do
    five_answers
    post_message("How am I doing this month?")
    assert_includes reply, "debt minimums"
    assert_includes response.parsed_body.dig("assistant_message", "setup_help", "money_inputs"), "debt"
    get "/api/v1/mia/messages", headers: headers
    assert_response :success
    assert_includes response.parsed_body.fetch("messages").last.dig("setup_help", "money_inputs"), "accounts"
  end

  test "M5 model-off purchase leads with the plan and creates no financial review" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    post_message("Can I afford a $300 stroller?")
    assert_match(/\AThe \$300 purchase/, reply)
    assert_includes reply, "$1,405"
    assert_includes reply, "$1,105"
    assert_nil response.parsed_body["mia_action_draft"]
    assert_nil response.parsed_body["transaction_draft"]
    assert_empty @household.household_transactions
    refute_match(/Plaid|posted outflows|unapproved|scenario only/i, reply)
  end

  private

  def headers
    { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  def post_message(message)
    post "/api/v1/mia/messages", params: { message: message }, headers: headers, as: :json
    assert_response :created
  end

  def reply
    response.parsed_body.dig("assistant_message", "content")
  end

  def five_answers
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz household", primary_goal: "Pay off Visa", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900").call
  end
end
