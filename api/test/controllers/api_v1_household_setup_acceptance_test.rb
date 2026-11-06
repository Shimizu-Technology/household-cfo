require "test_helper"

class ApiV1HouseholdSetupAcceptanceTest < ActionDispatch::IntegrationTest
  NUMBERS = "We bring home $5,200 each month. Rent is $1,800, utilities $250, groceries $700, and the car loan minimum is $350.".freeze

  setup do
    travel_to Time.zone.local(2026, 11, 4, 12)
    @user = User.create!(clerk_id: "w12_#{SecureRandom.hex(8)}", email: "w12-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  test "the production chat sequence completes all five essentials and shares the current month answer" do
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    assert_includes reply, "What would you like to call this household?"

    post_message(NUMBERS)
    draft = response.parsed_body.fetch("mia_action_draft")
    assert_equal "action_plan", draft.fetch("draft_type")
    assert_includes draft.fetch("rationale"), "Fixed essentials $2,050 (rent $1,800 + utilities $250)"
    assert_includes draft.fetch("rationale"), "Groceries $700 go under flexible spending"
    assert_equal 0, @household.income_sources.count
    assert_equal 0, @household.debts.count
    assert_equal [], @household.reload.confirmed_setup_fields
    apply(draft)
    assert_month_picture(@applied || response.parsed_body)
    assert_equal 4, @applied.dig("workspace", "setup_status", "completed_count")
    car = @household.debts.sole
    assert_equal 35000, car.minimum_payment_cents
    refute car.balance_known?
    assert_equal Date.new(2026, 11, 1), @household.income_sources.sole.starts_on
    assert_nil @applied.dig("budget", "annual_plan", "monthly_income", @applied.dig("budget", "annual_plan", "months", 9, "id").to_s)

    post_message("Call it the QA Test household.")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert_equal "QA Test household", draft.fetch("items").find { |i| i["action_type"] == "update_household_profile" }.dig("payload", "name")
    apply(draft)
    assert_equal 5, @applied.dig("workspace", "setup_status", "completed_count")
    refute_includes reply, "Home snapshot"

    post_message("What else do you need from me to finish setting up?")
    assert_includes reply, "Still to add: primary goal."
    refute_match(/readiness|verdict|safe-to-spend/i, reply)

    post_message("Build a $1,000 emergency cushion")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert_equal "household_setup", draft.fetch("draft_type")
    assert_equal 0, @household.goals.tracked.count
    apply(draft)
    assert @applied.dig("workspace", "setup_complete")
    assert_equal 6, @applied.dig("workspace", "setup_status", "completed_count")
    assert_includes reply, "Your household setup is complete."
    assert_equal "Build a $1,000 emergency cushion", @household.reload.primary_goal
    goal = @household.goals.tracked.sole
    assert_equal 100000, goal.target_amount_cents
    assert goal.target_amount_known?
    refute goal.current_amount_known?
    assert_month_picture(@applied || response.parsed_body)
    refute_includes @household.confirmed_setup_fields, "business_income"

    post_message("How am I doing this month?")
    assert_equal 520000, response.parsed_body.dig("month_answer", "money_in_cents")
    assert_equal 210000, response.parsed_body.dig("month_answer", "plan_left_cents")
    assert_includes reply, "$2,100"
    assert_includes reply, "November 2026"

    post_message("How did October look?")
    assert_includes reply, "Your plan starts in November"
    refute_match(/short|\$0/, reply)
  end

  test "R2 approved October spending agrees between Mia and the Budget report after a November join" do
    post_message(NUMBERS)
    apply(response.parsed_body.fetch("mia_action_draft"))
    period = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 10, 1))
    category = @household.budget_categories.find_by!(stack_key: "discretionary")
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: period.starts_on,
      merchant: "Approved October groceries", total_amount_cents: 12300, source_type: "statement", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 12300)
    @household.transaction_drafts.create!(occurred_on: period.starts_on, merchant: "Pending October groceries", total_amount_cents: 90000,
      budget_category: category, source_type: "statement", status: "pending")
    post_message("How did October look?")
    assert_equal 12300, response.parsed_body.dig("month_answer", "spent_so_far_cents")
    assert_nil response.parsed_body.dig("month_answer", "money_in_cents")
    assert_includes reply, "From your approved statement lines, you spent $123 in October 2026."
    refute_includes reply, "$900"
    get "/api/v1/spending_report?start_on=2026-10-01&end_on=2026-10-31", headers: headers
    assert_response :success
    assert_equal 123, response.parsed_body.dig("spending_report", "totals", "actual")
    assert_equal 900, response.parsed_body.dig("spending_report", "totals", "pending")
  end

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

  test "finishing chat setup in the manual form preserves the approved November income source" do
    post_message(NUMBERS)
    apply(response.parsed_body.fetch("mia_action_draft"))
    source = @household.income_sources.sole
    patch "/api/v1/workspace/setup", params: { workspace: {
      household_name: "QA Test household", primary_goal: "Build a $1,000 emergency cushion", primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700
    } }, headers: headers.merge(setup_revision_header(@user)).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert_month_picture(response.parsed_body)
    assert response.parsed_body.dig("workspace", "setup_complete")
    assert_equal [ source.id ], @household.income_sources.pluck(:id)
    assert_equal Date.new(2026, 11, 1), source.reload.starts_on
  end

  test "legacy joined setup CTA accepts the stated facts without treating them as a verdict request" do
    [ "#{HouseholdFinance::MiaSetupGuide::SETUP_REQUEST}#{NUMBERS}", "#{NUMBERS}#{HouseholdFinance::MiaSetupGuide::SETUP_REQUEST}" ].each do |message|
      post_message(message)
      assert response.parsed_body["mia_action_draft"], response.parsed_body.inspect
      refute_match(/cannot give|not enough approved|did not add anything/i, reply)
    end
  end

  test "a corrected household name supersedes only its previous pending setup card" do
    post_message("Call it the QA Test household.")
    first = response.parsed_body.fetch("mia_action_draft")
    post_message("Name it the QA Family.")
    second = response.parsed_body.fetch("mia_action_draft")
    assert_equal "canceled", @household.mia_action_drafts.find(first.fetch("id")).status
    assert_equal [ second.fetch("id") ], @household.mia_action_drafts.pending.pluck(:id)
    assert @household.mia_action_drafts.find(first.fetch("id")).mia_action_items.all?(&:canceled_at)
    refute_equal "QA Family", @household.reload.name
    apply(second)
    assert_equal "QA Family", @household.reload.name
  end

  test "missing setup never invents zero and hardship takes precedence over intake" do
    get "/api/v1/workspace", headers: headers
    assert_nil response.parsed_body.dig("dashboard", "month_answer", "money_in_cents")
    post_message("I can't afford food. #{NUMBERS}")
    assert_nil response.parsed_body["mia_action_draft"]
    assert_match(/food|essentials/i, reply)
  end

  test "canceling a setup review uses plain language and leaves the household unchanged" do
    post_message("Call it the QA Test household.")
    draft = response.parsed_body.fetch("mia_action_draft")
    before = @household.reload.name
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/cancel", headers: headers, as: :json
    assert_response :success
    assert_includes reply, "That review card is canceled."
    refute_includes reply, "assistant review draft"
    assert_equal before, @household.reload.name
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

  test "a previously tracked goal also completes the missing primary goal without a duplicate" do
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "0").call
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "QA Test household", primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700 }).call
    @household.goals.create!(label: "Emergency cushion", goal_type: "savings", record_kind: "tracked", target_amount_cents: 100000, target_amount_known: true)
    post_message("Build a $1,000 emergency cushion")
    draft = response.parsed_body.fetch("mia_action_draft")
    refute draft.fetch("items").any? { |item| item["action_type"] == "create_goal" }
    apply(draft)
    assert @applied.dig("workspace", "setup_complete")
    assert_equal 1, @household.goals.tracked.count
  end

  test "everyday interruptions never become a primary goal and hardship wins without a provider" do
    post_message("Call it the Reyes Family.")
    apply(response.parsed_body.fetch("mia_action_draft"))
    original_goal = @household.reload.primary_goal
    [ "I just spent $45 at Payless on groceries", "My rent is $1,500 a month", "We pay $1,600 rent each month", "Our power bill runs about $180 monthly", "I lost my job and cannot pay rent" ].each do |message|
      post_message(message)
      draft = response.parsed_body["mia_action_draft"]
      refute draft && draft.fetch("items").any? { |item| item.dig("payload", "primary_goal") == message || item.dig("payload", "value") == message }, message
      assert_nil draft, "A rent bill cannot establish a total for all fixed essentials" if message.match?(/(?:rent|power)/) && !message.include?("lost my job")
      assert_match(/housing|rent|food|essentials/i, reply) if message.include?("lost my job")
      refute_match(/approved data|readiness, safe-to-spend/i, reply)
      assert_equal original_goal, @household.reload.primary_goal
    end
  end

  test "natural setup start and minimum payment sentences prepare reviews without a model" do
    post_message("Help me set up my household")
    assert_includes reply, "What would you like to call this household?"
    post_message("Call it the Reyes Family.")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("Save for a house")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("I take home $4,800 a month")
    first = response.parsed_body.fetch("mia_action_draft")
    post_message("Actually make that $4,500 a month")
    second = response.parsed_body.fetch("mia_action_draft")
    assert_equal "canceled", @household.mia_action_drafts.find(first.fetch("id")).status
    apply(second)
    assert_equal 450000, @household.income_sources.sole.amount_cents
    post_message("$2,000")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("We spend around $900 a month on groceries, gas and everything else")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("$350 minimum on the Visa")
    draft = response.parsed_body.fetch("mia_action_draft")
    apply(draft)
    assert @applied.dig("workspace", "setup_complete")
    assert_includes reply, "Your household setup is complete."
    assert_equal 35000, @household.debts.sole.minimum_payment_cents
    refute @household.debts.sole.balance_known?
    post_message("I got a raise to $5,200 a month")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert_equal 450000, @household.income_sources.sole.amount_cents
    apply(draft)
    post_message("Change my main money goal to save for a house")
    refute_match(/approved data/i, reply)
    assert_match(/already|review/i, reply)
  end

  test "goal reviews do not display unknown monthly income as zero" do
    post_message("Call it the Reyes Family.")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("Save for a house")
    impact = response.parsed_body.fetch("mia_action_draft")["impact"]
    assert_nil impact && impact["before_monthly_income"]
    assert_nil impact && impact["after_monthly_income"]
  end

  test "yes to the setup confirmation uses participant words and stays a review" do
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    session.chat_messages.create!(role: "user", content: "Our household is called The Reyes Family. Our monthly income is $3,900.")
    session.chat_messages.create!(role: "assistant", content: "Is your household name 'The Reyes Family', and is $3,900 your monthly take-home income?")
    post_message("Yes")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert_equal 0, @household.income_sources.count
    apply(draft)
    assert_equal "The Reyes Family", @household.reload.name
    assert_equal 390000, @household.income_sources.sole.amount_cents
  end

  test "yes confirms setup facts given in separate earlier turns before a setup restart" do
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    [ "$3,900", "The Reyes Family of Mangilao and Dededo Guam with Grandma Rosa and the Three Kids Too", "Help me set up my household" ].each do |content|
      session.chat_messages.create!(role: "user", content: content)
    end
    session.chat_messages.create!(role: "assistant", content: 'Happy to help. Is your household name "The Reyes Family", and is $3,900 your monthly take-home income?')
    post_message("Yes")
    draft = response.parsed_body.fetch("mia_action_draft")
    assert draft, response.parsed_body.inspect
    assert_equal 0, @household.income_sources.count
    apply(draft)
    assert_equal "The Reyes Family", @household.reload.name
    assert_equal 390000, @household.income_sources.sole.amount_cents
  end

  test "an open monthly income review accepts a natural correction without a model" do
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "Reyes Family", primary_goal: "Save for a house" }).call
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("I take home $4,800 a month")
    first = response.parsed_body.fetch("mia_action_draft")
    post_message("Actually make that $4,500 a month")
    corrected = response.parsed_body.fetch("mia_action_draft")
    assert_equal "canceled", @household.mia_action_drafts.find(first["id"]).status
    apply(corrected)
    assert_equal 450000, @household.income_sources.sole.amount_cents
  end

  test "a named minimum after the debt question keeps the balance unknown and finishes setup" do
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "Reyes Family", primary_goal: "Save for a house", primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900 }).call
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("$350 minimum on the Visa")
    apply(response.parsed_body.fetch("mia_action_draft"))
    assert_equal 35000, @household.debts.sole.minimum_payment_cents
    refute @household.debts.sole.balance_known?
    assert_includes reply, "Your household setup is complete."
  end

  test "a raise and a main money goal change work as separate reviews without a provider" do
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "Reyes Family", primary_goal: "Save for emergencies", primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900 }).call
    post_message("I got a raise to $5,200 a month")
    income = response.parsed_body.fetch("mia_action_draft")
    assert_equal "income_schedule", income["draft_type"]
    post_message("Change my main money goal to save for a house")
    goal = response.parsed_body.fetch("mia_action_draft")
    assert_equal "household_setup", goal["draft_type"]
    assert_equal 480000, @household.income_sources.sole.amount_cents
    refute_equal "save for a house", @household.reload.primary_goal
  end

  [ "Actually $4,600", "Make that $4,600 instead", "Change that to $4,600", "It's actually $4,600", "No, $4,600" ].each_with_index do |sentence, index|
    test "review model off correction wording #{index}" do
      save_setup(primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900)
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

  test "review duplicate raises replace the older pending amount" do
    save_setup(primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900)
    post_message("I got a raise to $5,300 a month")
    older = response.parsed_body.fetch("mia_action_draft")
    post_message("I got a raise to $5,600 a month")
    newer = response.parsed_body.fetch("mia_action_draft")
    assert_equal "canceled", @household.mia_action_drafts.find(older["id"]).status
    post "/api/v1/mia_action_drafts/#{older['id']}/apply", headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    apply(newer)
    assert_equal 560000, @household.income_sources.sole.income_schedule_entries.order(:id).last.amount_cents
  end

  [ "The Mastercard minimum is $325", "$325 a month on the Mastercard" ].each_with_index do |sentence, index|
    test "review named debt minimum natural wording #{index}" do
      save_setup(primary_income: 4800, fixed_expenses: 2000, flexible_spend: 900)
      post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
      post_message(sentence)
      apply(response.parsed_body.fetch("mia_action_draft"))
      assert_equal 32500, @household.debts.sole.minimum_payment_cents
      refute @household.debts.sole.balance_known?
    end
  end

  test "review setup interruptions keep participant language and no fabricated ledger" do
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    [ "skip", "what does fixed essentials mean", "How much should I save?" ].each do |sentence|
      post_message(sentence)
      refute_match(/approved data|posted.*transactions.*\$0/i, reply)
      assert_nil response.parsed_body["mia_action_draft"]
    end
  end

  test "review ok after applying setup does not replay the applied action" do
    post_message("Our monthly income is $4,700")
    apply(response.parsed_body.fetch("mia_action_draft"))
    post_message("OK")
    refute_match(/already match|lost the exact request/i, reply)
    assert_nil response.parsed_body["mia_action_draft"]
  end

  test "review a purchase before categories exist explains deferral and repeats setup" do
    save_setup
    post_message(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    post_message("I spent $37 at Kmart today")
    draft = response.parsed_body.fetch("transaction_draft")
    assert draft, response.parsed_body.inspect
    assert_includes reply, "after setup"
    assert_includes reply, "primary monthly take-home income"
    assert_equal 0, @household.budget_categories.count
    assert_equal 0, @household.household_transactions.count
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
