require "test_helper"

class MiaFreshQaHouseholdTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    user = User.create!(clerk_id: "fresh_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz household", primary_goal: "Pay off Visa", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900").call
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household)
    @plan = @manager.plan_data
  end
  teardown { travel_back }

  test "M3 five setup answers still need debt minimums and name the actual gap" do
    status = HouseholdFinance::SetupStatus.new(@household)
    assert status.complete?
    assert_equal [ "debt_payment" ], status.missing_field_keys
    assert_includes HouseholdFinance::MiaSetupGuide.new(@household).after_apply_message, "debt"
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: @plan)
    assert_includes answer.response, "debt minimums"
    refute_includes answer.response, "missing income"
  end

  test "M4 a pre-plan month cannot compare with a zero plan and missing spending stays unknown" do
    report = HouseholdFinance::SpendingReport.new(@household, start_on: Date.new(2026, 8, 1), end_on: Date.new(2026, 8, 31)).as_json
    refute report[:plan_available]
    text = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "How did I do in August?").call
    assert_includes text, "Your plan starts in November 2026"
    assert_includes text, "not known yet"
    refute_match(/\$0|exactly|over the planned|under the planned/, text)
    assert_nil HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: @plan).call[:spent_so_far_cents]
  end

  test "M5 purchase answer uses plan even when no cash balance has been entered" do
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    result = HouseholdFinance::MiaHypotheticalScenarioAnswerer.new(@household, scenario_type: "purchase", amount: "300", label: "Stroller", annual_budget_manager: @manager, reference_month: 11).call
    assert_match(/\A.*\$300.*\$1,405/, result.body)
    assert_includes result.body, "$1,105"
    assert_includes result.body, "Stroller"
    assert_includes result.body, "plan"
    assert_match(/cash|account balance/, result.body)
    assert_equal 1, result.body.count("?")
    refute_match(/liquid account picture|unapproved|Plaid|safe-to-spend/, result.body)
  end

  test "M4 mixed year reports do not create a plan for years before the household joined" do
    refute @household.budget_years.exists?(year: 2025)
    report = HouseholdFinance::SpendingReport.new(@household, start_on: Date.new(2025, 12, 1), end_on: Date.new(2026, 11, 30)).as_json
    refute report[:plan_available]
    refute @household.budget_years.exists?(year: 2025)
  end

  test "M6 skipped meals get food support and a coach next step rather than a bill question" do
    message = "I skipped meals this week so the kids could eat"
    assert_equal :hardship, HouseholdFinance::MiaCoachAnswerer.routing_priority(message)
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, message).call
    assert_match(/\A[^.!?]*\b(?:food|eat|meals)\b/i, answer)
    assert_includes answer, "coach"
    assert_match(/food.*today|eat.*today/i, answer)
    refute_match(/which bill|discipline|proud|great job|protected baseline/i, answer)
  end

  test "hardship offers coach support without assuming a service is available" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "I lost my job hours and I cannot pay rent").call
    assert_includes answer, "coach"
    assert_match(/contact|talk|reach/i, answer)
  end
end
