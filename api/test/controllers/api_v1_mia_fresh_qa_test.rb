require "test_helper"
require_relative "../support/participant_reader_test_support"

class ApiV1MiaFreshQaTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    @user = User.create!(clerk_id: "fresh_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  test "M8 with the reader off setup says so, offers the form and writes nothing" do
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("$3,900")
    assert_match(/try again/i, reply)
    assert_match(/Enter my numbers/, reply)
    post_message("I take home about $4,800 a month")
    assert_match(/Enter my numbers/, reply)
    assert_nil response.parsed_body["mia_action_draft"]
    assert_equal 0, @household.income_sources.count
  end

  test "M3 setup is not complete until debts are answered" do
    five_answers
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    refute_includes reply, "setup is complete"
    assert_includes reply, "debts"
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
    assert_match(/\AThis month’s plan.*\$300 stroller/, reply)
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
