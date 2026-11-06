require "test_helper"

class HouseholdFinanceSetupReviewTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 4, 12)
    @user = User.create!(clerk_id: SecureRandom.uuid, email: "#{SecureRandom.uuid}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @session = @household.chat_sessions.create!(user: @user, title: "Setup")
  end
  teardown { travel_back }

  test "M1 October is unknown before November income and Mia explains the start" do
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    answer = HouseholdFinance::MiaMonthAnswer.for_question(@household, "How did October look?")
    assert_nil answer.call[:money_in_cents]
    assert_nil answer.call[:planned_out_cents]
    assert_nil answer.call[:plan_left_cents]
    assert_includes answer.response, "Your plan starts in November"
    refute_match(/short|\$0/, answer.response)
  end

  test "M1 and M2 budget overviews reuse the same unknown answer" do
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    before = HouseholdFinance::BudgetQuestionAnswerer.new("Explain my October budget", annual_plan: manager.plan_data).call
    assert_includes before, "Your plan starts in November"
    refute_match(/short|\$0/, before)
    @household.income_sources.destroy_all
    @household.update!(confirmed_setup_fields: %w[fixed_expenses flexible_spend])
    @household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 100000, cadence: "monthly", starts_on: Date.current.beginning_of_month)
    partial = HouseholdFinance::BudgetQuestionAnswerer.new("Explain my November budget", annual_plan: manager.plan_data).call
    assert_includes partial, "still to add: your main income"
    refute_includes partial, "$1,000"
  end

  test "M1 future and ended sources cannot establish known zero" do
    [ [ Date.new(2026, 12, 1), nil ], [ Date.new(2026, 1, 1), Date.new(2026, 11, 1) ] ].each do |starts, ends|
      @household.income_sources.destroy_all
      @household.income_sources.create!(label: "Job", source_type: "job", amount_cents: 520000, cadence: "monthly", starts_on: starts, ends_on: ends)
      assert_nil month_answer[:money_in_cents]
    end
  end

  test "M2 business and rental alone are partial and main income is still missing" do
    %w[business rental].each do |type|
      @household.income_sources.destroy_all
      @household.income_sources.create!(label: type, source_type: type, amount_cents: 100000, cadence: "monthly", starts_on: Date.current.beginning_of_month)
      answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: manager.plan_data)
      assert_nil answer.call[:money_in_cents]
      assert_nil answer.call[:plan_left_cents]
      context = JSON.parse(HouseholdFinance::MiaContextBuilder.new(@household).call)
      assert_nil context.dig("metrics", "monthly_income")
      assert_includes answer.response.downcase, "still to add: your main income"
      assert_nil manager.plan_data[:annual_outlook][:months].last[:income]
    end
  end

  test "M2 confirmed primary zero permits other income and current job needs no optional business confirmation" do
    save_manual(primary_income: 0)
    assert_equal 0, month_answer[:money_in_cents]
    @household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 100000, cadence: "monthly", starts_on: Date.current.beginning_of_month)
    assert_equal 100000, month_answer[:money_in_cents]
    @household.update!(confirmed_setup_fields: [])
    @household.income_sources.create!(label: "Job", source_type: "job", amount_cents: 520000, cadence: "monthly", starts_on: Date.current.beginning_of_month)
    assert_equal 620000, month_answer[:money_in_cents]
  end

  test "M3 chat and manual November setup have identical income costs debt and outlook" do
    text = "We bring home $5,200 each month. Rent $1,800, utilities $250, groceries $700, and the car loan minimum $350."
    intake = HouseholdFinance::MiaSetupIntake.new(text, context: { setup_status: { complete: false }, active_debts: [] }).call
    proposal = HouseholdFinance::MiaActionPlanBuilder.new(@household, user: @user, annual_budget_manager: manager, selected_month: 11,
      raw_input: text, actions: intake.write_plan[:actions]).call.proposal
    draft = persist(proposal)
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(idempotency_key: SecureRandom.uuid)
    assert applied.success?, applied.errors.inspect
    chat = manager.plan_data
    assert_equal Date.new(2026, 11, 1), @household.income_sources.sole.starts_on
    assert_equal [ 0 ] * 10, chat[:rows].first[:months].first(10).map { |cell| cell[:planned] }
    assert chat[:annual_outlook][:months].all? { |month| month[:starts_on] >= "2026-11-01" }
    assert_equal [ 350, 350 ], chat[:annual_outlook][:months].map { |month| month[:debt_minimums] }
    assert_equal [ 2100, 2100 ], chat[:annual_outlook][:months].map { |month| month[:baseline_surplus] }
    @household.income_sources.destroy_all
    @household.budget_categories.destroy_all
    @household.expense_items.destroy_all
    @household.update!(confirmed_setup_fields: [])
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    manual = manager.plan_data
    assert_equal Date.new(2026, 11, 1), @household.income_sources.sole.starts_on
    assert_equal chat[:monthly_income], manual[:monthly_income]
    assert_equal chat[:rows].map { |row| row[:months].map { |cell| cell[:planned] } }, manual[:rows].map { |row| row[:months].map { |cell| cell[:planned] } }
    assert_equal chat[:annual_outlook], manual[:annual_outlook]
    following = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2027).plan_data
    assert_equal [ 2050, 700 ], following[:rows].map { |row| row[:months].first[:planned] }
  end

  test "m4 card rationale never claims a different fixed total or absent car minimum" do
    proposal = plan("Rent 1,800, utilities 250, insurance 350; fixed essentials are $2,400", fixed_expenses: 2400)
    refute_includes proposal.rationale, "$2,050"
    refute_includes proposal.summary, "car minimum"
  end

  test "m5 corrected action plan supersedes only fully covered same-session fields" do
    old = persist(plan("Rent 1,800, utilities 250", fixed_expenses: 2050))
    unrelated = persist(setup_proposal("Name it Other", household_name: "Other"))
    other_user = User.create!(clerk_id: SecureRandom.uuid, email: "#{SecureRandom.uuid}@example.invalid", role: "participant")
    other = @household.chat_sessions.create!(user: other_user, title: "Other")
    elsewhere = persist(plan("Rent 1,800, utilities 250", fixed_expenses: 2050), session: other)
    replacement = persist(plan("Rent 1,900, utilities 250", fixed_expenses: 2150))
    assert_equal "canceled", old.reload.status
    assert old.mia_action_items.all?(&:canceled_at)
    [ unrelated, elsewhere, replacement ].each { |draft| assert_equal "pending", draft.reload.status }
  end

  test "m5 corrected setup goal supersedes create and update goal cards" do
    first = persist(setup_proposal("Build a $1,000 emergency cushion", primary_goal: "Build a $1,000 emergency cushion"))
    assert first.mia_action_items.exists?(action_type: "create_goal")
    persist(setup_proposal("Build a $2,000 emergency cushion", primary_goal: "Build a $2,000 emergency cushion"))
    assert_equal "canceled", first.reload.status
    goal = @household.goals.create!(label: "Emergency cushion", goal_type: "savings", record_kind: "tracked", target_amount_cents: 100000, target_amount_known: true)
    old = persist(setup_proposal("Build a $3,000 emergency cushion", primary_goal: "Build a $3,000 emergency cushion"))
    assert old.mia_action_items.exists?(action_type: "update_goal")
    persist(setup_proposal("Build a $4,000 emergency cushion", primary_goal: "Build a $4,000 emergency cushion"))
    assert_equal "canceled", old.reload.status
    assert_equal 100000, goal.reload.target_amount_cents
  end

  test "m5 a separate goal update survives a setup replacement and cancellation is atomic" do
    goal = @household.goals.create!(label: "Trip", goal_type: "travel", record_kind: "tracked", target_amount_cents: 100000, target_amount_known: true)
    text = "Name it Family; set Trip target to $2,000"
    proposal = HouseholdFinance::MiaActionPlanBuilder.new(@household, user: @user, annual_budget_manager: manager, selected_month: 11,
      raw_input: text, actions: [
        { source_text: "Name it Family", action: { type: "update_household_setup", setup_updates: { household_name: "Family" } } },
        { source_text: "set Trip target to $2,000", action: { type: "update_goal", goal_id: goal.id, target_amount: 2000 } }
      ]).call.proposal
    separate = persist(proposal)
    persist(setup_proposal("Name it New Family", household_name: "New Family"))
    assert_equal "pending", separate.reload.status
    assert_equal 100000, goal.reload.target_amount_cents

    old = persist(plan("Rent 1,800, utilities 250", fixed_expenses: 2050))
    replacement = plan("Rent 1,900, utilities 250", fixed_expenses: 2150)
    failed = Object.new
    failed.define_singleton_method(:call) { |**| HouseholdFinance::MiaActionDraftCanceler::Result.new(success?: false, errors: [ "cannot cancel" ]) }
    original_new = HouseholdFinance::MiaActionDraftCanceler.method(:new)
    HouseholdFinance::MiaActionDraftCanceler.define_singleton_method(:new) { |*| failed }
    assert_no_difference("MiaActionDraft.count") do
      assert_raises(ArgumentError) { persist(replacement) }
    end
    assert_equal "pending", old.reload.status
  ensure
    HouseholdFinance::MiaActionDraftCanceler.define_singleton_method(:new, original_new) if original_new
  end

  test "m6 approximate amounts keep their values and uncertainty on the review card" do
    text = "Rent $1,800, utilities about $250, groceries about $700"
    intake = HouseholdFinance::MiaSetupIntake.new(text)
    assert_equal 205000, intake.fixed_cents
    assert_includes intake.fixed_description, "about $250"
    assert_includes intake.fixed_description, "about $700"
    proposal = setup_proposal(text, fixed_expenses: 2050, flexible_spend: 700)
    assert_includes proposal.items.map(&:description).join(" "), "about $250"
  end

  test "m6 standalone income groceries and car minimum keep their estimate labels" do
    { primary_income: [ "We bring home about $5,200", 5200 ], flexible_spend: [ "Groceries about $700", 700 ] }.each do |field, (text, value)|
      proposal = setup_proposal(text, **{ field => value })
      assert_includes proposal.rationale, "about $#{value == 5200 ? '5,200' : '700'}"
    end
    text = "Rent $1,800, utilities $250, and the car loan minimum is about $350."
    intake = HouseholdFinance::MiaSetupIntake.new(text, context: { setup_status: { complete: false }, active_debts: [] }).call
    proposal = HouseholdFinance::MiaActionPlanBuilder.new(@household, user: @user, annual_budget_manager: manager, selected_month: 11,
      raw_input: text, actions: intake.write_plan[:actions]).call.proposal
    assert_includes proposal.items.find { |item| item.action_type == "create_debt" }.description, "Car minimum is about $350"
  end

  test "CR setup values preserve saved costs when the current allocation is missing" do
    save_manual(fixed_expenses: 2050)
    category = @household.budget_categories.find_by!(stack_key: "non_discretionary")
    category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(2026, 11, 1) }).destroy!
    values = HouseholdFinance::DataPresenter.new(@household).setup_values
    assert_equal 2050, values[:fixed_expenses]
    save_manual(**values.slice(:fixed_expenses))
    assert_equal 205000, @household.expense_items.find_by!(stack_key: "non_discretionary").amount_cents
    assert_equal 2050, HouseholdFinance::DataPresenter.new(@household).setup_values[:fixed_expenses]
  end

  test "CR a confirmation only card keeps its confirmation explanation" do
    save_manual(fixed_expenses: 2050)
    category = @household.budget_categories.find_by!(stack_key: "non_discretionary")
    @household.expense_items.find_by!(stack_key: "non_discretionary").update!(label: "Monthly bills")
    category.update!(name: "Monthly bills")
    @household.update!(confirmed_setup_fields: [])
    proposal = setup_proposal("Rent $1,800 and utilities $250", fixed_expenses: 2050)
    confirmation = proposal.items.find { |item| item.action_type == "confirm_household_setup" }
    assert_includes confirmation.description, "Save these details as part of your household setup"
    assert_includes proposal.rationale, "rent $1,800 + utilities $250"
  end

  test "CR selected month income knowledge and amount include the same midmonth job" do
    @household.income_sources.create!(label: "Job", source_type: "job", amount_cents: 520000, cadence: "monthly", starts_on: Date.new(2026, 11, 15))
    context = JSON.parse(HouseholdFinance::MiaContextBuilder.new(@household, annual_plan: manager.plan_data, reference_month: 11).call)
    assert_equal true, context.dig("metrics", "monthly_income_known")
    assert_equal "$5,200", context.dig("metrics", "monthly_income")
  end

  test "CR call it only names a household while that name is missing" do
    complete = { setup_status: { complete: true, missing_fields: [] } }
    [ "Call it Pets.", "Name it Pets.", "Call it #{'Pets ' * 40}." ].each do |text|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: text, context: complete, api_key: nil).call
      refute_equal "household_setup", result&.topic&.dig(:type), text
      assert_nil result&.action&.dig(:setup_updates, :household_name), text
    end
    missing = { setup_status: { complete: false, missing_fields: [ { key: "household_name" } ] } }
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "Call it Pets.", context: missing, api_key: nil).call
    assert_equal "Pets", result.action.dig(:setup_updates, :household_name)
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "Call our household Pets.", context: complete, api_key: nil).call
    assert_equal "Pets", result.action.dig(:setup_updates, :household_name)
  end

  test "CR unicode car whitespace returns to the validated planner" do
    result = HouseholdFinance::MiaSetupIntake.new("Rent $1,800, utilities $250, and the car loan minimum\u00a0$350.",
      context: { setup_status: { complete: false }, active_debts: [] }).call
    assert_nil result
  end

  test "CR a confirmed primary zero survives a future optional income source" do
    save_manual(primary_income: 0)
    @household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 100000, cadence: "monthly", starts_on: Date.new(2026, 12, 1))
    assert_equal 0, month_answer[:money_in_cents]
    @household.update!(confirmed_setup_fields: [])
    assert_nil month_answer[:money_in_cents]
    @household.update!(confirmed_setup_fields: [ "primary_income" ])
    @household.income_sources.create!(label: "Future job", source_type: "job", amount_cents: 520000, cadence: "monthly", starts_on: Date.new(2026, 12, 1))
    assert_equal 0, month_answer[:money_in_cents]
  end

  test "R2 L1 pre start approved spending survives without a plan comparison" do
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    october = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 10, 1))
    category = @household.budget_categories.find_by!(stack_key: "discretionary")
    transaction = @household.household_transactions.create!(budget_period: october, occurred_on: october.starts_on,
      merchant: "Approved October groceries", total_amount_cents: 12345, source_type: "statement", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 12345)
    @household.transaction_drafts.create!(occurred_on: october.starts_on, merchant: "Pending October groceries", total_amount_cents: 90000,
      budget_category: category, source_type: "statement", status: "pending")
    answer = HouseholdFinance::MiaMonthAnswer.for_question(@household, "How did October look?")
    assert_equal 12345, answer.call[:spent_so_far_cents]
    assert_nil answer.call[:money_in_cents]
    assert_nil answer.call[:planned_out_cents]
    assert_nil answer.call[:plan_left_cents]
    assert_includes answer.response, "October 2026 has no plan to compare against"
    assert_includes answer.response, "From your approved statement lines, you spent $123 in October 2026."
    refute_includes answer.response, "$900"
    overview = HouseholdFinance::BudgetQuestionAnswerer.new("Explain my October budget", annual_plan: manager.plan_data).call
    assert_includes overview, "$123"
    assert_equal 123.45, manager.plan_data[:rows].find { |row| row[:id] == category.id }[:months][9][:actual]
  end

  test "R2 L1 pre start absent or pending only spending stays unknown" do
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    [ false, true ].each do |pending|
      if pending
        @household.transaction_drafts.create!(occurred_on: Date.new(2026, 10, 1), merchant: "Pending October groceries", total_amount_cents: 90000,
          budget_category: @household.budget_categories.find_by!(stack_key: "discretionary"), source_type: "statement", status: "pending")
      end
      answer = HouseholdFinance::MiaMonthAnswer.for_question(@household, "How did October look?")
      assert_nil answer.call[:spent_so_far_cents]
      refute_match(/\$[0-9]/, answer.response)
      assert_includes answer.response, "Approved spending for October 2026 is not known yet"
    end
  end

  test "R2 C1 changing a confirmed primary goal updates its tracked target only after approval" do
    save_manual(primary_goal: "Build a $1,000 emergency cushion")
    goal = @household.goals.create!(label: "Emergency cushion", goal_type: "savings", record_kind: "tracked", target_amount_cents: 100000, target_amount_known: true)
    draft = persist(setup_proposal("Build a $2,000 emergency cushion", primary_goal: "Build a $2,000 emergency cushion"))
    assert draft.mia_action_items.exists?(action_type: "update_goal")
    assert_equal 100000, goal.reload.target_amount_cents
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(idempotency_key: SecureRandom.uuid)
    assert applied.success?, applied.errors.inspect
    assert_equal "Build a $2,000 emergency cushion", @household.reload.primary_goal
    assert_equal 200000, goal.reload.target_amount_cents
    assert_equal 1, @household.goals.tracked.count
    proposal = setup_proposal("Save a $2,000 emergency cushion", primary_goal: "Save a $2,000 emergency cushion")
    refute proposal.items.any? { |item| item.action_type.in?(%w[create_goal update_goal]) }
  end

  [ :setup_proposal, :plan ].each do |builder|
    test "R2 C2 #{builder} cards mention only groceries that they save" do
      text = "Rent $1,800, utilities $250, groceries $700"
      [ {}, { flexible_spend: 600 }, { flexible_spend: 700 } ].each do |extra|
        proposal = send(builder, text, fixed_expenses: 2050, **extra)
        assert_includes proposal.rationale, "rent $1,800 + utilities $250"
        descriptions = [ proposal.rationale, *proposal.items.map(&:description) ].join(" ")
        if extra[:flexible_spend] == 700
          assert_includes descriptions, "Groceries $700 go under flexible spending"
        else
          refute_includes descriptions, "Groceries $700 go under flexible spending"
        end
      end
    end
  end

  test "R2 C3 a confirmed primary and explicitly ended job establish known zero" do
    save_manual(primary_income: 5200)
    @household.income_sources.sole.update!(ends_on: Date.new(2026, 11, 1))
    assert_equal 0, month_answer[:money_in_cents]
    assert_equal 0, manager.plan_data[:annual_outlook][:months].first[:income]
  end

  test "R2 C3 confirmed nonzero primary plus only a future job remains unknown" do
    save_manual(primary_income: 5200)
    @household.income_sources.sole.update!(starts_on: Date.new(2026, 12, 1))
    assert_nil month_answer[:money_in_cents]
  end

  test "R2 C3 explicit primary zero plus a future job stays known zero" do
    save_manual(primary_income: 0)
    @household.income_sources.create!(label: "Future job", source_type: "job", amount_cents: 520000, cadence: "monthly", starts_on: Date.new(2026, 12, 1))
    assert_equal 0, month_answer[:money_in_cents]
  end

  test "R2 L1 approved totals do not rely on truncated transaction lists" do
    save_manual(primary_income: 5200, fixed_expenses: 2050, flexible_spend: 700)
    october = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 10, 1))
    category = @household.budget_categories.find_by!(stack_key: "discretionary")
    9.times do |index|
      transaction = @household.household_transactions.create!(budget_period: october, occurred_on: october.starts_on,
        merchant: "Approved #{index}", total_amount_cents: 1000, source_type: "statement", status: "reconciled")
      transaction.transaction_splits.create!(budget_category: category, amount_cents: 1000)
    end
    ignored = @household.household_transactions.create!(budget_period: october, occurred_on: october.starts_on,
      merchant: "Ignored", total_amount_cents: 99900, source_type: "statement", status: "ignored")
    ignored.transaction_splits.create!(budget_category: category, amount_cents: 99900)
    data = manager.plan_data
    assert_equal 8, data[:recent_transactions].size
    data[:pending_transaction_drafts_meta][:truncated] = true
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: data, month: 10)
    assert_equal 9000, answer.call[:spent_so_far_cents]
    assert_nil answer.call[:pending_cents]
    assert_includes answer.response, "you spent $90"
  end

  test "R2 C2 already saved groceries are not described as a new update" do
    save_manual(flexible_spend: 700)
    [ :setup_proposal, :plan ].each do |builder|
      proposal = send(builder, "Rent $1,800, utilities $250, groceries $700", fixed_expenses: 2050, flexible_spend: 700)
      refute_includes [ proposal.rationale, *proposal.items.map(&:description) ].join(" "), "Groceries $700 go under flexible spending"
    end
  end

  test "R2 C3 latest primary confirmation and generation determine explicit zero" do
    save_manual(primary_income: 0)
    save_manual(primary_income: 5200)
    @household.income_sources.sole.update!(starts_on: Date.new(2026, 12, 1))
    assert_nil month_answer[:money_in_cents]
    save_manual(primary_income: 0)
    assert_equal 0, month_answer[:money_in_cents]
    @household.household_operation_executions.update_all(financial_generation: @household.financial_generation - 1)
    assert_nil month_answer[:money_in_cents]
  end

  private

  def manager
    HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
  end

  def month_answer
    HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: manager.plan_data).call
  end

  def save_manual(**attributes)
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, attributes: attributes, idempotency_key: SecureRandom.uuid).call
  end

  def setup_proposal(text, **updates)
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: manager, selected_month: 11,
      raw_input: text, command: { type: "update_household_setup", setup_updates: updates }).call
    assert result.proposal, result.response
    result.proposal
  end

  def plan(text, **updates)
    result = HouseholdFinance::MiaActionPlanBuilder.new(@household, user: @user, annual_budget_manager: manager, selected_month: 11,
      raw_input: text, actions: [ { source_text: text, depends_on: [], action: { type: "update_household_setup", setup_updates: updates } } ]).call
    assert result.proposal, result.response
    result.proposal
  end

  def persist(proposal, session: @session)
    source = session.chat_messages.create!(role: "user", content: proposal.source_prompt)
    assistant = session.chat_messages.create!(role: "assistant", content: proposal.summary)
    proposal.create_draft!(source_chat_message: source, assistant_chat_message: assistant)
  end
end
