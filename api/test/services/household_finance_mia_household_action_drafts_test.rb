require "test_helper"

class HouseholdFinanceMiaHouseholdActionDraftsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.local(2026, 10, 6, 12)
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

  teardown { travel_back }

  test "drafts and applies multiple approved household values through the supervised boundary" do
    result = build_command(
      type: "update_household_setup",
      setup_updates: {
        primary_goal: "Build a twelve-thousand-dollar emergency fund",
        primary_income: "6200",
        emergency_fund: "3500",
        unexpected_sinking_fund: "225"
      }
    )

    assert_equal "household_setup", result.proposal.draft_type
    assert_equal 6, result.proposal.items.length
    assert_equal %w[confirm_household_setup create_category update_account update_household_profile update_transition_policy upsert_income_schedule_entry], result.proposal.items.map(&:action_type).sort
    assert_equal 5_500.0, result.proposal.metadata.dig(:impact, :before_monthly_income)
    assert_equal 6_700.0, result.proposal.metadata.dig(:impact, :after_monthly_income)

    draft = persist(result.proposal)
    operation_keys = draft.mia_action_items.pluck(:operation_key)
    assert_equal "profile.setup_confirmation.update", operation_keys.last
    assert_includes operation_keys, "profile.household.update"
    assert_includes operation_keys, "goal.transition_policy.update"
    assert_includes operation_keys, "income.schedule.create"
    assert_includes operation_keys, "budget.category.create"
    assert_includes operation_keys, "account.record.update"
    refute_includes draft.mia_action_items.pluck(:action_type), "update_setup_value"
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    setup = HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values
    assert_equal "Build a twelve-thousand-dollar emergency fund", setup.fetch(:primary_goal)
    assert_equal 6_200.0, setup.fetch(:primary_income)
    assert_equal 3_500.0, setup.fetch(:emergency_fund)
    assert_equal 225.0, setup.fetch(:unexpected_sinking_fund)
    assert_equal "applied", draft.reload.status
    executions = HouseholdOperationExecution.where(reviewable: draft.mia_action_items)
    assert_equal operation_keys.sort, executions.pluck(:operation_key).sort
  end

  test "setup confirmation cannot bypass typed financial operations" do
    error = assert_raises(ArgumentError) do
      HouseholdFinance::Operations::Profile::SetupConfirmationUpdate.new(@household).prepare(
        updates: { primary_income: 9_999 },
        confirmed_fields: [ "primary_income" ]
      )
    end

    assert_includes error.message, "cannot change household values"
    assert_equal 5_000.0, HouseholdFinance::DataPresenter.new(@household.reload).setup_values.fetch(:primary_income)
  end

  test "household profile operation does not mutate an untracked transition policy" do
    transition = @household.goals.policy.find_by!(goal_type: "transition")
    original_label = transition.label

    HouseholdFinance::Operations::Runner.new(@household, user: @user).run(
      operation_key: "profile.household.update",
      input: { primary_goal: "Choose a new direction" },
      idempotency_key: "profile-goal-without-policy-side-effect"
    )

    assert_equal "Choose a new direction", @household.reload.primary_goal
    assert_equal original_label, transition.reload.label
  end

  test "setup impact keeps outflow and surplus unknown when the debt minimum is unknown" do
    @household.household_profile.update!(
      debt_summary_minimum_payment_cents: 0,
      debt_summary_minimum_payment_known: false
    )

    result = build_command(
      type: "update_household_setup",
      setup_updates: { unexpected_sinking_fund: "225" }
    )

    impact = result.proposal.metadata.fetch(:impact)
    assert_equal 5_500.0, impact.fetch(:before_monthly_income)
    assert_equal 5_500.0, impact.fetch(:after_monthly_income)
    assert_nil impact.fetch(:before_monthly_outflow)
    assert_nil impact.fetch(:after_monthly_outflow)
    assert_nil impact.fetch(:before_baseline_surplus)
    assert_nil impact.fetch(:after_baseline_surplus)
  end

  test "drafts and atomically applies the complete first-session picture" do
    result = build_command(
      type: "update_household_setup",
      setup_updates: {
        household_name: "QA Test Family",
        primary_goal: "Build a six-month emergency fund",
        primary_income: "6200",
        fixed_expenses: "3000",
        flexible_spend: "800",
        expected_sinking_fund: "250",
        unexpected_sinking_fund: "125"
      }
    )

    assert_equal 9, result.proposal.items.length
    assert_equal 3_400.0, result.proposal.metadata.dig(:impact, :before_monthly_outflow)
    assert_equal 4_325.0, result.proposal.metadata.dig(:impact, :after_monthly_outflow)
    before = HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values
    assert_equal 2_500.0, before.fetch(:fixed_expenses)
    assert_equal 750.0, before.fetch(:flexible_spend)

    draft = persist(result.proposal)
    coverage = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:setup_coverage_after_apply)
    assert coverage.fetch(:complete)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    setup = HouseholdFinance::DataPresenter.new(@household.reload, user: @user).setup_values
    assert_equal "QA Test Family", setup.fetch(:household_name)
    assert_equal 6_200.0, setup.fetch(:primary_income)
    assert_equal 3_000.0, setup.fetch(:fixed_expenses)
    assert_equal 800.0, setup.fetch(:flexible_spend)
    assert_equal 250.0, setup.fetch(:expected_sinking_fund)
    assert_equal 125.0, setup.fetch(:unexpected_sinking_fund)
    assert HouseholdFinance::SetupStatus.new(@household).complete?
  end

  test "persists a complete eleven-field setup even when it expands to thirteen reviewed operations" do
    result = build_command(
      type: "update_household_setup",
      setup_updates: {
        household_name: "Complete Setup Household",
        primary_goal: "Build enough runway for a careful transition",
        primary_income: "6200",
        business_income: "900",
        fixed_expenses: "3100",
        flexible_spend: "825",
        expected_sinking_fund: "275",
        unexpected_sinking_fund: "150",
        emergency_fund: "4500",
        other_assets: "7200",
        target_runway_months: "8"
      }
    )

    assert_equal 13, result.proposal.items.length
    draft = persist(result.proposal)

    assert_equal 13, draft.mia_action_items.count
    assert_equal "profile.setup_confirmation.update", draft.mia_action_items.last.operation_key
  end

  test "transition goal review shows the exact normalized label that will be saved" do
    primary_goal = "Build a thoughtful transition plan with enough time to protect the household and make the next decision carefully " * 2
    result = build_command(type: "update_household_setup", setup_updates: { primary_goal: primary_goal })
    draft = persist(result.proposal)
    transition_item = draft.mia_action_items.find_by!(operation_key: "goal.transition_policy.update")
    expected_label = primary_goal.squish.truncate(80, omission: "…")

    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items)
      .find { |item| item.fetch(:id) == transition_item.id }
    transition_field = review.fetch(:review_fields).sole

    assert_equal "Transition goal", transition_field.fetch(:label)
    assert_equal expected_label, transition_field.fetch(:after)
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal expected_label, @household.goals.policy.find_by!(goal_type: "transition").label
  end

  test "shows which first-session fields will still be missing after a partial review" do
    @household.update!(confirmed_setup_fields: [ "household_name" ], primary_goal: nil)
    @household.expense_items.delete_all
    result = build_command(type: "update_household_setup", setup_updates: { primary_income: "6200" })
    draft = persist(result.proposal)

    coverage = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:setup_coverage_after_apply)

    refute coverage.fetch(:complete)
    assert_equal [ "Primary goal", "Fixed essentials", "Flexible spending" ], coverage.fetch(:missing_fields).pluck(:label)
  end

  test "counts a newly proposed primary goal in first-session review coverage" do
    @household.update!(primary_goal: nil, confirmed_setup_fields: [])
    result = build_command(
      type: "update_household_setup",
      setup_updates: {
        household_name: @household.name,
        primary_goal: "Build a six-month emergency fund",
        primary_income: "5000",
        fixed_expenses: "2500",
        flexible_spend: "750"
      }
    )
    draft = persist(result.proposal)

    coverage = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:setup_coverage_after_apply)

    assert coverage.fetch(:complete)
    assert_empty coverage.fetch(:missing_fields)
  end

  test "reviews and confirms unchanged required defaults including explicit zero" do
    @household.expense_items.where(stack_key: "discretionary").update_all(amount_cents: 0, active: false)
    @household.update!(confirmed_setup_fields: %w[primary_goal primary_income fixed_expenses])

    result = build_command(
      type: "update_household_setup",
      setup_updates: { household_name: @household.name, flexible_spend: "0" }
    )

    assert_equal 1, result.proposal.items.length
    assert_equal "confirm_household_setup", result.proposal.items.sole.action_type
    assert_equal %w[flexible_spend household_name], result.proposal.items.sole.payload.fetch(:confirmed_fields).sort

    draft = persist(result.proposal)
    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert apply.success?, apply.errors.to_sentence
    status = HouseholdFinance::SetupStatus.new(@household.reload)
    assert status.complete?
    assert_includes status.confirmed_field_keys, "household_name"
    assert_includes status.confirmed_field_keys, "flexible_spend"
  end

  test "confirmation-only setup reviews reject a value that changed after review" do
    @household.expense_items.where(stack_key: "discretionary").update_all(amount_cents: 0, active: false)
    @household.update!(confirmed_setup_fields: @household.confirmed_setup_fields - [ "flexible_spend" ])
    result = build_command(type: "update_household_setup", setup_updates: { flexible_spend: "0" })
    draft = persist(result.proposal)
    @household.expense_items.create!(
      label: "New flexible spending", stack_key: "discretionary", amount_cents: 100_00,
      cadence: "monthly", active: true
    )

    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    refute apply.success?
    assert_includes apply.errors.to_sentence, "changed since Mia prepared"
    refute_includes HouseholdFinance::SetupStatus.new(@household.reload).confirmed_field_keys, "flexible_spend"
    assert_equal "pending", draft.reload.status
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

  test "aggregate setup treats a future-ending source as current without creating a duplicate" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.find_by!(source_type: "job")
      source.update!(active: false, ends_on: Date.new(2026, 12, 1))
      result = build_command(type: "update_household_setup", setup_updates: { primary_income: "5500" })

      apply = HouseholdFinance::MiaActionDraftApplier.new(persist(result.proposal), user: @user).call

      assert apply.success?, apply.errors.to_sentence
      assert_equal 1, @household.income_sources.where(source_type: "job").count
      refute source.reload.active?
      assert_equal Date.new(2026, 12, 1), source.ends_on
      assert_equal 550_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.current)
    end
  end

  test "aggregate setup rejects ambiguity from multiple current sources including a future-ending one" do
    travel_to Date.new(2026, 10, 15) do
      @household.income_sources.create!(
        label: "Temporary role", source_type: "job", amount_cents: 100_000, cadence: "monthly",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 1), active: false
      )

      result = build_command(type: "update_household_setup", setup_updates: { primary_income: "6500" })

      assert_nil result.proposal
      assert_includes result.response, "multiple saved income sources"
    end
  end

  test "Mia can update and cancel a future income source then apply the zero-length timeline" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(
        label: "Future contract", source_type: "business", amount_cents: 200_000, cadence: "monthly", starts_on: Date.new(2027, 2, 1)
      )
      update = build_command(
        type: "update_income_source", income_source_id: source.id, income_source_name: source.label, amount: "2500"
      )
      update_apply = HouseholdFinance::MiaActionDraftApplier.new(persist(update.proposal), user: @user).call
      assert update_apply.success?, update_apply.errors.to_sentence
      assert_equal 250_000, source.reload.amount_cents

      cancel = build_command(
        type: "archive_income_source", income_source_id: 0, income_source_name: source.label, effective_on: "2026-10-01"
      )
      cancel_draft = persist(cancel.proposal)
      item = cancel_draft.mia_action_items.sole
      assert_equal source.starts_on.iso8601, item.prepared_operation.dig("normalized_input", "ends_on")
      boundary = HouseholdFinance::MiaActionDraftPresenter.new(cancel_draft).call
        .fetch(:items).sole.fetch(:review_fields).find { |field| field.fetch(:label) == "First $0 month" }
      assert_equal "$0 beginning February 2027", boundary.fetch(:after)

      cancel_apply = HouseholdFinance::MiaActionDraftApplier.new(cancel_draft, user: @user).call
      assert cancel_apply.success?, cancel_apply.errors.to_sentence
      refute source.reload.active?
      assert_equal source.starts_on, source.ends_on
      assert_equal "archived", source.timeline_status(on: Date.current)
    end
  end

  test "Mia does not rewrite or offer restore reviews for income that ended in the past" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.find_by!(source_type: "job")
      source.update!(active: false, ends_on: Date.new(2026, 1, 1))

      update = build_command(
        type: "update_income_source", income_source_id: source.id, income_source_name: source.label, amount: "9000"
      )
      schedule = build_command(
        type: "schedule_income_change", income_source_id: source.id, income_source_name: source.label,
        entry_type: "recurring_change", effective_on: "2025-06-01", amount: "7000"
      )
      restore = build_command(
        type: "restore_income_source", income_source_id: source.id, income_source_name: source.label
      )

      [ update, schedule, restore ].each do |result|
        assert_nil result.proposal
        assert_includes result.response, "could not"
      end
      assert_equal 500_000, source.reload.amount_cents
      assert_empty source.income_schedule_entries
    end
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
    assert_includes apply.errors.to_sentence, "income timeline changed"
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
    assert_includes apply.errors.to_sentence, "income timeline changed"
    assert_empty source.income_schedule_entries.where(effective_on: Date.new(2026, 10, 1))
    assert_equal "pending", draft.reload.status
  end

  test "rejects an equivalent monthly value when the reviewed source cadence changed" do
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
    source.update!(amount_cents: 6_000_000, cadence: "annual")

    assert_equal 500_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source.reload, on: Date.new(2026, 10, 1))

    apply = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    refute apply.success?
    assert_includes apply.errors.to_sentence, "income timeline changed"
    assert_empty source.income_schedule_entries.where(effective_on: Date.new(2026, 10, 1))
    assert_equal "pending", draft.reload.status
  end

  test "returns validation instead of crashing when a scheduled income update has an invalid month" do
    source = @household.income_sources.find_by!(source_type: "job")
    entry = source.income_schedule_entries.create!(
      entry_type: "recurring_change", amount_cents: 550_000, cadence: "monthly", effective_on: Date.new(2026, 10, 1)
    )

    result = build_command(
      type: "update_income_schedule_entry",
      income_schedule_entry_id: entry.id,
      effective_on: "not-a-month",
      amount: "6000",
      cadence: "monthly"
    )

    assert_nil result.proposal
    assert_includes result.response, "valid month"
    assert_equal 550_000, entry.reload.amount_cents
  end

  test "setup global impact is omitted when other or rental income is outside starting fields" do
    %w[other rental].each do |kind|
      source = @household.income_sources.create!(label: "Synthetic #{kind} income", source_type: kind, amount_cents: 50_000, cadence: "monthly", starts_on: Date.current.beginning_of_month)
      @household.reload
      assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "MiaActionDraft.count" ] do
        result = build_command(type: "update_household_setup", setup_updates: { target_runway_months: "9" })
        assert result.proposal
        refute result.proposal.metadata.key?(:impact)
        runway = result.proposal.items.find { |item| item.action_type == "update_runway_policy" }
        assert_equal 6.0, runway.before_snapshot.fetch(:target_months)
        assert_equal 9.0, runway.after_snapshot.fetch(:target_months)
      end
      source.destroy!
      @household.reload
    end
  end

  test "setup global impact is omitted when current one-time income changes monthly plan cash in" do
    source = @household.income_sources.find_by!(source_type: "job")
    source.income_schedule_entries.create!(entry_type: "one_time", label: "Synthetic bonus", amount_cents: 50_000, cadence: "one_time", effective_on: Date.current.beginning_of_month)
    result = build_command(type: "update_household_setup", setup_updates: { target_runway_months: "9" })
    assert result.proposal
    refute result.proposal.metadata.key?(:impact)
    plan = @manager.read_only_plan_data
    period = plan.fetch(:months).fetch(Date.current.month - 1)
    assert_equal 6_000.0, plan.fetch(:monthly_income).fetch(period.fetch(:id))
  end

  test "setup global impact omits custom allocations and offsetting stack differences" do
    reading = @manager.create_category!(name: "Synthetic Reading", stack_key: "discretionary", monthly_amount: 0)
    reading_allocation = reading.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.current.beginning_of_month })
    @manager.update_allocation!(reading_allocation, "30")
    result = build_command(type: "update_household_setup", setup_updates: { target_runway_months: "9" })
    assert result.proposal
    refute result.proposal.metadata.key?(:impact)
    @manager.archive_category!(reading)
    period = @manager.current_period_for(Date.current)
    fixed = period.budget_allocations.joins(:budget_category).find_by!(budget_categories: { stack_key: "non_discretionary", active: true })
    flexible = period.budget_allocations.joins(:budget_category).find_by!(budget_categories: { stack_key: "discretionary", active: true })
    @manager.update_allocation!(fixed, "2600")
    @manager.update_allocation!(flexible, "650")
    result = build_command(type: "update_household_setup", setup_updates: { fixed_expenses: "3000" })
    assert result.proposal
    refute result.proposal.metadata.key?(:impact)
    change = result.proposal.items.find { |item| item.action_type == "update_allocation" }.payload.fetch(:changes).find { |row| row[:month] == Date.current.month }
    assert_equal 260_000, change.fetch(:before_cents)
    assert_equal 300_000, change.fetch(:after_cents)
  end

  test "future-year setup policy review has exact item values without a current-month global panel" do
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2027)
    @manager.ensure_plan!
    assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count" ] do
      result = build_command(type: "update_household_setup", setup_updates: { target_runway_months: "9" })
      assert result.proposal
      refute result.proposal.metadata.key?(:impact)
      assert_equal 2027, result.proposal.year
    end
  end

  test "explicit recurring cadences apply with impact equal to the canonical income timeline" do
    %w[weekly biweekly annual].each do |cadence|
      source = @household.income_sources.find_by!(source_type: "job")
      result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: cadence, effective_on: "2026-11-01")
      assert result.proposal, result.response
      item = result.proposal.items.sole
      assert_equal cadence, item.payload.fetch(:cadence)
      assert_equal cadence, item.after_snapshot.fetch(:cadence)
      equivalent = HouseholdFinance::Money.period_cents(15_000, cadence, month: 11)
      assert_equal equivalent, item.after_snapshot.fetch(:effective_monthly_cents)
      draft = persist(result.proposal)
      applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
      assert applied.success?, applied.errors.to_sentence
      entry = source.income_schedule_entries.find_by!(effective_on: Date.new(2026, 11, 1))
      assert_equal 15_000, entry.amount_cents
      assert_equal cadence, entry.cadence
      plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
      period = plan.fetch(:months).fetch(10)
      assert_equal plan.fetch(:monthly_income).fetch(period.fetch(:id)), result.proposal.metadata.dig(:impact, :after_monthly_income)
      assert_equal equivalent, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source.reload, on: Date.new(2026, 11, 1))
      duplicate = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: cadence, effective_on: "2026-11-01")
      assert_nil duplicate.proposal
      assert_includes duplicate.response, "already scheduled"
    end
  end

  test "invalid recurring cadence is rejected and one-time entry keeps its fixed cadence" do
    source = @household.income_sources.find_by!(source_type: "job")
    [ "daily", "one_time" ].each do |cadence|
      result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: cadence, effective_on: "2026-11-01")
      assert_nil result.proposal
      assert_includes result.response, "supported recurring income cadence"
    end
    result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "one_time", amount: "150", cadence: "weekly", effective_on: "2026-11-01")
    assert_equal "one_time", result.proposal.items.sole.payload.fetch(:cadence)
  end

  test "schedule preview does not create a missing future budget year" do
    source = @household.income_sources.find_by!(source_type: "job")
    assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count", "IncomeScheduleEntry.count" ] do
      result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: "weekly", effective_on: "2027-01-01")
      assert result.proposal
      assert_nil result.proposal.metadata[:impact]
      assert_equal "weekly", result.proposal.items.sole.payload.fetch(:cadence)
      assert_equal 65_000, result.proposal.items.sole.after_snapshot.fetch(:effective_monthly_cents)
    end
  end

  test "schedule impact preserves unknown outflow instead of inferring missing debt minimums as zero" do
    @household.household_profile.update!(debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: false)
    source = @household.income_sources.find_by!(source_type: "job")
    result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: "weekly", effective_on: "2026-11-01")
    assert result.proposal
    assert_equal 1150.0, result.proposal.metadata.dig(:impact, :after_monthly_income)
    assert_nil result.proposal.metadata.dig(:impact, :before_monthly_outflow)
    assert_nil result.proposal.metadata.dig(:impact, :after_baseline_surplus)
  end

  test "income impact excludes archived category plans retained with historical actuals" do
    historical = @manager.create_category!(name: "Archived synthetic spending", stack_key: "discretionary", monthly_amount: 100)
    period = @manager.current_period_for(Date.new(2026, 9, 1))
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: "2026-09-02", merchant: "Synthetic historical purchase", total_amount_cents: 1_000, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: historical, amount_cents: 1_000)
    @manager.archive_category!(historical)
    @household.income_sources.each { |source| source.update!(starts_on: "2026-01-01") }
    source = @household.income_sources.find_by!(source_type: "job")
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).read_only_plan_data
    archived = plan.fetch(:rows).find { |row| row[:id] == historical.id }
    assert_equal false, archived.fetch(:active)
    assert_equal 100.0, archived.fetch(:months).fetch(8).fetch(:planned)
    result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "one_time", amount: "150", effective_on: "2026-09-01")
    assert result.proposal
    snapshot = HouseholdFinance::SnapshotBuilder.new(@household, reference_date: Date.new(2026, 9, 1), ensure_plan: false).call
    assert_equal 3_400.0, result.proposal.metadata.dig(:impact, :before_monthly_outflow)
    assert_equal snapshot.fetch(:total_outflow_cents), HouseholdFinance::Money.cents(result.proposal.metadata.dig(:impact, :after_monthly_outflow))
  end

  test "income impact keeps future outflow unknown when an active category allocation is missing" do
    future = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2027)
    future.ensure_plan!
    category = @manager.create_category!(name: "New synthetic category", stack_key: "discretionary", monthly_amount: 50)
    missing = future.read_only_plan_data.fetch(:rows).find { |row| row[:id] == category.id }.fetch(:months).first
    assert_equal true, missing.fetch(:allocation_missing)
    source = @household.income_sources.find_by!(source_type: "job")
    assert_no_difference [ "BudgetYear.count", "BudgetAllocation.count" ] do
      result = build_command(type: "schedule_income_change", income_source_id: source.id, entry_type: "recurring_change", amount: "150", cadence: "weekly", effective_on: "2027-01-01")
      assert result.proposal
      assert_equal 1150.0, result.proposal.metadata.dig(:impact, :after_monthly_income)
      assert_nil result.proposal.metadata.dig(:impact, :before_monthly_outflow)
      assert_nil result.proposal.metadata.dig(:impact, :after_monthly_outflow)
      assert_nil result.proposal.metadata.dig(:impact, :before_baseline_surplus)
      assert_nil result.proposal.metadata.dig(:impact, :after_baseline_surplus)
    end
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
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    user_message = session.chat_messages.create!(role: "user", content: "Please update my numbers")
    assistant_message = session.chat_messages.create!(role: "assistant", content: "I prepared a review")
    proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message)
  end
end
