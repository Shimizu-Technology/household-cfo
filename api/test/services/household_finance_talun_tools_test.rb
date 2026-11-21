require "test_helper"

class HouseholdFinanceTalunToolsTest < ActiveSupport::TestCase
  test "Talun approved facts feed both tools without saving a possibility or counting a bonus" do
    user = User.create!(clerk_id: "talun-tools", email: "talun-tools@example.test", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Talun household")
    household.household_memberships.create!(user: user, role: "owner")
    HouseholdFinance::SetupUpdater.new(household, household_name: "Talun household", primary_goal: "Build a business",
      primary_income: "5400", business_income: "0", fixed_expenses: "2600", flexible_spend: "1300", expected_sinking_fund: "250", unexpected_sinking_fund: "150",
      emergency_fund: "3200", target_runway_months: "3", credit_card_debt: "1800", debt_payment: "90").call
    source = household.income_sources.find_by!(source_type: "job")
    source.income_schedule_entries.create!(entry_type: "one_time", label: "Invented bonus", amount_cents: 200_000,
      cadence: "one_time", effective_on: Date.current.beginning_of_month)
    household.income_sources.create!(label: "Invented bonus source", source_type: "bonus", amount_cents: 10_000, cadence: "monthly")
    presenter = HouseholdFinance::DataPresenter.new(household.reload, ensure_plan: false)
    before = [ household.reload.attributes, household.accounts.map(&:attributes), household.income_sources.map(&:attributes),
      household.debts.map(&:attributes), BudgetAllocation.count, IncomeScheduleEntry.count ]
    filter = presenter.cfo_filter_scenario(spend_cents: 10_000, windfall_cents: 100_000)
    runway = presenter.optionality_scenario
    assert_equal 540_000, filter[:facts][:income_cents]
    assert_equal 439_000, filter[:facts][:costs_cents]
    assert_equal 101_000, filter[:base_surplus_cents]
    assert_equal 1_202_000, filter[:after_spend_surplus_cents]
    assert_equal filter[:facts][:savings_cents], runway[:inputs][:savings_cents]
    assert_equal filter[:facts][:costs_cents], runway[:inputs][:monthly_costs_cents]
    assert_equal 439_000, runway[:monthly_draw_cents]
    assert_equal 1, runway[:months]
    mia = ->(message) { HouseholdFinance::MiaCoachAnswerer.new(household, message, ensure_plan: false).call }
    transition_answer = mia.call("How long could we last if I quit to run my business?")
    assert_includes transition_answer, "lasts approximately 1 months"
    assert_includes mia.call("How long will our savings last if I quit my job?"), "Your transition runway"
    assert_includes mia.call("How long could we last if I quit to run my business and draw $500 per month?"), "$500 drawn from savings"
    assert_includes mia.call("How long could we last if I quit to run my business and draw $0 per month?"), "from month one"
    assert_includes mia.call("How long could we last if I quit to run my business and draw $10000000 per month?"), "$9,999,999.99 or less"
    hidden_tool_guidance = CohortExperience::MiaModuleGuidance.new(modules: [ { id: "optionality", enabled: false } ])
    refute_includes hidden_tool_guidance.filter(transition_answer), "Optionality"
    assert_equal transition_answer, hidden_tool_guidance.filter(transition_answer)
    assert_includes mia.call("What does it take to get to green?"), "Emergency fund: $651.67 monthly income lift"
    assert_equal 0, filter[:targets][0][:yellow][:extra_cents]
    assert_equal 65_167, filter[:targets][0][:green][:extra_cents]
    assert_equal 20, filter[:before][:emergency_months]
    assert_equal 12, presenter.cfo_filter_scenario(lift_cents: 65_167)[:lifted][:emergency_months]
    assert_equal 13, presenter.cfo_filter_scenario(lift_cents: 65_166)[:lifted][:emergency_months]
    assert_includes mia.call("Can I afford $100?"), "CFO Filter:"
    assert_equal before, [ household.reload.attributes, household.accounts.map(&:attributes), household.income_sources.map(&:attributes),
      household.debts.map(&:attributes), BudgetAllocation.count, IncomeScheduleEntry.count ]
    capabilities = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: nil).call.deep_dup
    capabilities[:modules].each { |item| item[:enabled] = false if %w[cfo_filter optionality].include?(item[:id]) }
    resolver = Struct.new(:call).new(capabilities)
    original = CohortExperience::EffectiveCapabilitiesResolver.method(:new)
    begin
      CohortExperience::EffectiveCapabilitiesResolver.define_singleton_method(:new) { |**| resolver }
      refute_includes mia.call("What does it take to get to green?").to_s, "monthly income lift"
      refute_includes mia.call("How long could we last if I quit to run my business?").to_s, "transition runway"
      refute_includes mia.call("Can I afford $100?").to_s, "CFO Filter:"
    ensure
      CohortExperience::EffectiveCapabilitiesResolver.define_singleton_method(:new, original)
    end
    household.update!(confirmed_setup_fields: household.confirmed_setup_fields - [ "business_income" ])
    household.income_sources.where(source_type: "business").destroy_all
    unknown = HouseholdFinance::DataPresenter.new(household.reload, ensure_plan: false).optionality_scenario
    assert_nil unknown[:monthly_draw_cents], "missing business income must not become $0"
    assert_nil unknown[:tone]
  end
end
