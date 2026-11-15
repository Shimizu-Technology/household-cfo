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

  test "F1 form saves known debt answers and leaves a blank payment unknown" do
    values = { household_name: "Form household", primary_goal: "A calm month", primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700, debt_payment: nil }
    save_form = ->(changes) do
      patch "/api/v1/workspace/setup", params: { workspace: values.merge(changes) }, headers: headers.merge(setup_revision_header(@user)).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
      assert_response :success
      response.parsed_body
    end
    partial = save_form.call({})
    assert partial.dig("workspace", "setup_complete")
    assert_equal 5, partial.dig("workspace", "setup_status", "completed_count")
    assert_equal [ "debt_payment" ], partial.dig("workspace", "setup_status", "missing_fields").map { |field| field.fetch("key") }
    assert_nil partial.dig("dashboard", "month_answer", "planned_out_cents")

    paid = save_form.call(debt_payment: 350)
    assert paid.dig("workspace", "setup_complete")
    assert_equal 310000, paid.dig("dashboard", "month_answer", "planned_out_cents")
    refute paid.dig("workspace", "debt_portfolio", "balance_known")
    post_message("How am I doing this month?")
    assert_includes reply, "$2,100"

    none = save_form.call(debt_payment: 0, credit_card_debt: 0)
    assert none.dig("workspace", "setup_complete")
    assert none.dig("workspace", "debt_portfolio", "balance_known")
    assert_equal 275000, none.dig("dashboard", "month_answer", "planned_out_cents")
    changed = save_form.call(debt_payment: 350, credit_card_debt: nil)
    assert changed.dig("workspace", "setup_complete")
    refute changed.dig("workspace", "debt_portfolio", "balance_known")
  end

  test "F1 invalid debt payment rejects the form before saving" do
    original_name = @household.name
    patch "/api/v1/workspace/setup", params: { workspace: { household_name: "Do not save", debt_payment: "12.345" } },
      headers: headers.merge(setup_revision_header(@user)).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    assert_equal original_name, @household.reload.name
    refute HouseholdFinance::DebtPortfolio.new(@household).minimum_payment_known?
  end

  test "F1 setup guide confirms a household with two payment-only debts" do
    @household.debts.create!(label: "Car", debt_type: "auto_loan", minimum_payment_cents: 20000, minimum_payment_known: true, balance_known: false)
    @household.debts.create!(label: "Card", debt_type: "credit_card", minimum_payment_cents: 15000, minimum_payment_known: true, balance_known: false)
    save_setup(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    assert HouseholdFinance::SetupStatus.new(@household.reload).complete?
    assert_includes HouseholdFinance::MiaSetupGuide.new(@household).after_apply_message, "setup is complete"
  end

  test "fix1 blank debt does not approve summary tracking or add a debt operation" do
    profile = @household.household_profile
    mode = profile.debt_tracking_mode
    assert_no_difference -> { @household.household_operation_executions.where(operation_key: "debt.tracking_mode.update").count } do
      save_setup(debt_payment: nil)
    end
    assert_equal mode, profile.reload.debt_tracking_mode
    refute profile.debt_summary_minimum_payment_known?
  end

  test "fix1 goal save preserves a December override on a single category during setup" do
    save_setup(fixed_expenses: 2050)
    category = @household.budget_categories.active.find_by!(stack_key: "non_discretionary")
    december = category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(2026, 12, 1) })
    december.update!(planned_amount_cents: 240000)
    save_setup(fixed_expenses: 2050, primary_goal: "A new goal")
    assert_equal 240000, december.reload.planned_amount_cents
    refute HouseholdFinance::SetupStatus.new(@household.reload).complete?
  end

  test "fix1 form answers clear only their own skips" do
    @household.update!(setup_skipped_fields: %w[primary_goal primary_income flexible_spend])
    save_setup(primary_goal: "A calm month", primary_income: 5200)
    assert_equal [ "flexible_spend" ], @household.reload.setup_skipped_fields
  end


  test "fix1 an applied action plan does not append optional debt questions to a set up household" do
    save_setup(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    account = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 10000, balance_known: true)
    goal = @household.goals.create!(label: "Trip", goal_type: "travel", record_kind: "tracked", current_amount_cents: 50000, current_amount_known: true)
    result = HouseholdFinance::MiaActionPlanBuilder.new(@household, user: @user,
      annual_budget_manager: HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026), selected_month: 11,
      raw_input: "Set Checking to $250 and Trip progress to $900",
      actions: [
        { source_text: "Set Checking to $250", depends_on: [], action: { type: "update_account", account_id: account.id, account_name: account.label, amount: "250" } },
        { source_text: "Trip progress to $900", depends_on: [], action: { type: "update_goal", goal_id: goal.id, goal_name: goal.label, current_amount: "900" } }
      ]).call
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    draft = result.proposal.create_draft!(source_chat_message: session.chat_messages.create!(role: "user", content: "Set Checking to $250 and Trip progress to $900"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this plan"))
    apply({ "id" => draft.id })
    message = ChatMessage.where(role: "assistant").order(:id).last
    assert_equal "Your reviewed changes are saved.", message.content
    refute message.setup_help.to_h["debt_balances"]
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
