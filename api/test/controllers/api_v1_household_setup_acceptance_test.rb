require "test_helper"
require_relative "../support/participant_reader_test_support"

class ApiV1HouseholdSetupAcceptanceTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  NUMBERS = "We bring home $5,200 each month. Rent is $1,800, utilities $250, groceries $700, and the car loan minimum is $350.".freeze

  setup do
    travel_to Time.zone.local(2026, 11, 4, 12)
    @user = User.create!(clerk_id: "w12_#{SecureRandom.hex(8)}", email: "w12-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  test "manual setup with only the five required fields does not require optional business income" do
    @household.debts.create!(label: "Car loan", debt_type: "auto_loan", minimum_payment_cents: 35000, minimum_payment_known: true, balance_known: false)
    patch "/api/v1/workspace/setup", params: { workspace: {
      household_name: "QA Test household", primary_goal: "Build a $1,000 emergency cushion", primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700
    } }, headers: headers.merge(setup_revision_header(@user)).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert response.parsed_body.dig("workspace", "setup_complete")
    assert_month_picture(@applied || response.parsed_body)
    assert_equal 5200, response.parsed_body.dig("workspace", "setup_values", "primary_income")
    assert_equal 1, @household.income_sources.count
  end

  test "missing setup never invents zero and hardship takes precedence over intake" do
    get "/api/v1/workspace", headers: headers
    assert_nil response.parsed_body.dig("dashboard", "month_answer", "money_in_cents")
    post_message("I can't afford food. #{NUMBERS}")
    assert_nil response.parsed_body["mia_action_draft"]
    assert_match(/food|essentials/i, reply)
  end

  test "approved income alone does not turn missing planned costs into zero" do
    @household.create_household_profile!(debt_tracking_mode: "summary", debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true) unless @household.household_profile
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true)
    patch "/api/v1/workspace/setup", params: { workspace: { primary_income: 5200 } }, headers: headers.merge(setup_revision_header(@user)).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert_equal 520000, response.parsed_body.dig("dashboard", "month_answer", "money_in_cents")
    assert_nil response.parsed_body.dig("dashboard", "month_answer", "planned_out_cents")
    assert_nil response.parsed_body.dig("dashboard", "month_answer", "plan_left_cents")
  end

  [ "Actually $4,600", "Make that $4,600 instead", "Change that to $4,600", "It's actually $4,600", "No, $4,600" ].each_with_index do |sentence, index|
    test "review model off correction wording #{index}" do
      save_setup(primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900)
      @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true)
      post_message("I got a raise to $5,300 a month")
      older = response.parsed_body.fetch("mia_action_draft")
      post_message(sentence)
      corrected = response.parsed_body.fetch("mia_action_draft")
      assert corrected, response.parsed_body.inspect
      assert_equal "canceled", @household.mia_action_drafts.find(older["id"]).status
      apply(corrected)
      assert_equal 460000, @household.income_sources.sole.income_schedule_entries.order(:id).last.amount_cents
    end
  end

  private

  def save_setup(**values)
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "Review household", primary_goal: "A house" }.merge(values)).call
  end


  def headers
    { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  def post_message(text)
    post "/api/v1/mia/messages", params: { message: text }, headers: headers, as: :json
    assert_response :created
  end

  def reply
    response.parsed_body.dig("assistant_message", "content").presence || response.parsed_body.dig("workspace", "mia", "messages")&.last&.fetch("content").to_s
  end

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    @applied = response.parsed_body.fetch("workspace")
  end

  def assert_month_picture(payload)
    answer = payload.fetch("dashboard").fetch("month_answer")
    assert_equal 520000, answer.fetch("money_in_cents")
    assert_equal 310000, answer.fetch("planned_out_cents")
    assert_equal 210000, answer.fetch("plan_left_cents")
    plan = payload.dig("budget", "annual_plan")
    november = plan.fetch("months").fetch(10)
    assert_equal 5200, plan.fetch("monthly_income").fetch(november.fetch("id").to_s)
    assert_equal 2100, payload.dig("wealth", "summary", "monthly_surplus_available")
  end
  def setup_revision_header(user)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    { "X-Setup-Revision" => HouseholdFinance::SetupRevision.for(household.reload) }
  end
end
