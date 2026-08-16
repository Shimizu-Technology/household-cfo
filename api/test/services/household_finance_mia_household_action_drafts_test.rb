require "test_helper"

class HouseholdFinanceMiaHouseholdActionDraftsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "household-actions-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Household Action Test")
    @household.household_memberships.create!(user: @user, role: "owner")
    HouseholdFinance::SetupUpdater.new(
      @household,
      primary_goal: "Protect the basics",
      primary_income: 5_000,
      business_income: 500,
      fixed_expenses: 2_500,
      flexible_spend: 750,
      emergency_fund: 2_000,
      credit_card_debt: 4_000,
      debt_payment: 150,
      target_runway_months: 6
    ).call
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @manager.ensure_plan!
  end

  test "drafts and applies multiple approved household values through the supervised boundary" do
    result = build_command(
      type: "update_household_setup",
      setup_updates: {
        primary_goal: "Build a twelve-thousand-dollar emergency fund",
        primary_income: "6200",
        emergency_fund: "3500",
        debt_payment: "225"
      }
    )

    assert_equal "household_setup", result.proposal.draft_type
    assert_equal 4, result.proposal.items.length
    assert_equal [ "update_setup_value" ], result.proposal.items.map(&:action_type).uniq
    assert_equal 5_500.0, result.proposal.metadata.dig(:impact, :before_monthly_income)
    assert_equal 6_700.0, result.proposal.metadata.dig(:impact, :after_monthly_income)

    draft = persist(result.proposal)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    setup = HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values
    assert_equal "Build a twelve-thousand-dollar emergency fund", setup.fetch(:primary_goal)
    assert_equal 6_200.0, setup.fetch(:primary_income)
    assert_equal 3_500.0, setup.fetch(:emergency_fund)
    assert_equal 225.0, setup.fetch(:debt_payment)
    assert_equal "applied", draft.reload.status
  end

  test "rejects a stale household value instead of overwriting a newer manual edit" do
    result = build_command(type: "update_household_setup", setup_updates: { primary_income: "6200" })
    draft = persist(result.proposal)
    HouseholdFinance::SetupUpdater.new(@household, primary_income: 5_800).call

    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    refute apply.success?
    assert_includes apply.errors.to_sentence, "changed since Mia prepared"
    assert_equal 5_800.0, HouseholdFinance::DataPresenter.new(@household.reload).setup_values.fetch(:primary_income)
    assert_equal "pending", draft.reload.status
  end

  test "drafts and applies an effective-dated income change" do
    source = @household.income_sources.find_by!(source_type: "job")
    result = build_command(
      type: "schedule_income_change",
      income_source_id: source.id,
      income_source_name: source.label,
      entry_type: "recurring_change",
      effective_on: "2026-10-01",
      amount: "7200",
      schedule_label: "October raise"
    )

    assert_equal "income_schedule", result.proposal.draft_type
    assert_equal "upsert_income_schedule_entry", result.proposal.items.first.action_type
    assert_equal "October 2026", result.proposal.metadata.dig(:impact, :scope)

    draft = persist(result.proposal)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    entry = source.income_schedule_entries.find_by!(effective_on: Date.new(2026, 10, 1))
    assert_equal 720_000, entry.amount_cents
    assert_equal "monthly", entry.cadence
    october = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
    october_period = october.fetch(:months).fetch(9)
    assert_equal 7_700.0, october.fetch(:monthly_income).fetch(october_period.fetch(:id))
  end

  test "allows a reviewed zero-dollar recurring change to end an income source" do
    source = @household.income_sources.find_by!(source_type: "business")
    result = build_command(
      type: "schedule_income_change",
      income_source_id: source.id,
      income_source_name: source.label,
      entry_type: "recurring_change",
      effective_on: "2026-11-01",
      amount: "0"
    )

    draft = persist(result.proposal)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    assert_equal 0, source.income_schedule_entries.find_by!(effective_on: Date.new(2026, 11, 1)).amount_cents
  end

  test "drafts one-time income without changing the recurring source amount" do
    source = @household.income_sources.find_by!(source_type: "job")
    result = build_command(
      type: "schedule_income_change",
      income_source_id: source.id,
      income_source_name: source.label,
      entry_type: "one_time",
      effective_on: "2026-12-01",
      amount: "400",
      schedule_label: "Year-end bonus"
    )

    draft = persist(result.proposal)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    entry = source.income_schedule_entries.find_by!(effective_on: Date.new(2026, 12, 1), entry_type: "one_time")
    assert_equal 40_000, entry.amount_cents
    assert_equal "one_time", entry.cadence
    assert_equal 500_000, source.reload.amount_cents
    december = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
    december_period = december.fetch(:months).fetch(11)
    assert_equal 5_900.0, december.fetch(:monthly_income).fetch(december_period.fetch(:id))
  end

  test "rejects a stale income draft instead of overwriting a newer schedule" do
    source = @household.income_sources.find_by!(source_type: "job")
    result = build_command(
      type: "schedule_income_change",
      income_source_id: source.id,
      income_source_name: source.label,
      entry_type: "recurring_change",
      effective_on: "2026-10-01",
      amount: "7200"
    )
    draft = persist(result.proposal)
    source.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 680_000,
      cadence: "monthly",
      effective_on: Date.new(2026, 10, 1)
    )

    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    refute apply.success?
    assert_includes apply.errors.to_sentence, "effective income changed"
    assert_equal 680_000, source.income_schedule_entries.find_by!(effective_on: Date.new(2026, 10, 1)).amount_cents
    assert_equal "pending", draft.reload.status
  end

  test "rejects an income draft when its reviewed effective starting amount became stale" do
    source = @household.income_sources.find_by!(source_type: "job")
    result = build_command(
      type: "schedule_income_change",
      income_source_id: source.id,
      income_source_name: source.label,
      entry_type: "recurring_change",
      effective_on: "2026-10-01",
      amount: "7200"
    )
    draft = persist(result.proposal)
    source.update!(amount_cents: 580_000)

    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    refute apply.success?
    assert_includes apply.errors.to_sentence, "effective income changed"
    assert_empty source.income_schedule_entries.where(effective_on: Date.new(2026, 10, 1))
    assert_equal "pending", draft.reload.status
  end

  private

  def build_command(command)
    HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: @manager,
      selected_month: 8,
      raw_input: "model resolved household command",
      command: command
    ).call
  end

  def persist(proposal)
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    user_message = session.chat_messages.create!(role: "user", content: "Please update my numbers")
    assistant_message = session.chat_messages.create!(role: "assistant", content: "I prepared a review")
    proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message)
  end
end
