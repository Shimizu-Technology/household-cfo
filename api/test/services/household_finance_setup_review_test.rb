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
