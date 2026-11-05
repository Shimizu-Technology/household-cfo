require "test_helper"

class MiaReviewLateFindingsTest < ActiveSupport::TestCase
  setup { travel_to Time.zone.local(2026, 11, 5, 12) }
  teardown { travel_back }

  test "undated purchases use the selected budget month while explicit timing wins" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Can I buy a $300 stroller?", annual_budget_manager: manager, reference_month: 12).call
    assert_includes answer, "December 2026"
    next_year = HouseholdFinance::AnnualBudgetManager.new(household, year: 2027)
    next_year.plan_data
    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Can I buy a $300 stroller?", annual_budget_manager: next_year, reference_month: 2).call
    assert_includes answer, "February 2027"
    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Can I buy a $300 stroller next month?", annual_budget_manager: manager, reference_month: 8).call
    assert_includes answer, "December 2026"
  end

  test "purchase corrections replace the earlier amount and ambiguous corrections clarify" do
    [ "Can I afford a $300 stroller? No, it costs $400", "Should I buy a $300 stroller? Actually, the price is $400", "Can I buy a $300 stroller? Sorry, I meant $400" ].each do |message|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "").deterministic_scenario_result
      assert_equal "400", result.read_only_plan[:items].first[:amount], message
    end
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "Can I buy a $300 stroller? Actually, the price is $400 or $450", context: {}, api_key: "").deterministic_scenario_result
    assert result.needs_clarification
  end

  test "purchase coaching rejects spelled money without blocking a practical one question" do
    [ "The plan would leave fifty bucks. Which category would fund it?", "The plan would leave fifty. Which category would fund it?", "It would leave forty five dollars. Which category would fund it?", "You would have twenty remaining. What would fund it?" ].each do |message|
      assert narrator("purchase_scenario").send(:narration_rejection_reason, message), message
    end
    [ "Protect food and bills first. What is one practical next step?", "Protect food and bills. Do you have one practical next step?" ].each { |message| assert_nil narrator("purchase_scenario").send(:narration_rejection_reason, message) }
  end

  test "food support must end with a household food question today" do
    [ "Food comes first. Talk with your coach today. Which bill is due next?", "You need food today and should talk with your coach. Can you postpone the stroller?" ].each do |message|
      assert narrator("coaching", "I missed meals so my kids could eat").send(:narration_rejection_reason, message), message
    end
    assert_nil narrator("coaching", "I missed meals so my kids could eat").send(:narration_rejection_reason, "You need food today; talk with your coach. Does everyone in your home have enough food today?")
  end

  test "explicit missed meals outrank an empty food budget but hypothetical hunger does not" do
    [ "I missed meals so my kids could eat, but my food budget is empty", "We went without dinner so our children could eat, and our grocery budget is empty" ].each do |message|
      assert HouseholdFinance::MoneyMovementText.food_insecurity?(message), message
    end
    refute HouseholdFinance::MoneyMovementText.food_insecurity?("What if I missed meals so my kids could eat, but my food budget was empty?")
    refute HouseholdFinance::MoneyMovementText.food_insecurity?("Last year I missed meals so my kids could eat, but my food budget was empty")
  end

  test "direct spending instructions fail but participant decision questions remain valid" do
    [ "You should buy the stroller. Which category would cover it?", "You should buy it, shouldn’t you?", "You ought to purchase it. What comes next?", "Book the trip. Which category would cover it?", "Please order it. What comes next?", "Buy it today. What comes next?" ].each do |message|
      assert_equal :purchase_verdict, Mia::NarrationClaims.rejection_reason(message), message
    end
    [ "Should you buy it before protecting food?", "Do you think you should buy it?", "You decide whether to buy it. Which category would cover it?" ].each do |message|
      assert_nil Mia::NarrationClaims.rejection_reason(message), message
    end
  end

  test "saved record descriptions never exempt a new passive write receipt" do
    [ "The saved plan was updated.", "The saved plan has just been updated.", "The saved plan was updated, but do not forget bills.", "Your existing records were logged.", "The previously recorded purchase has been updated." ].each do |message|
      assert_equal :false_write_claim, Mia::NarrationClaims.rejection_reason(message), message
    end
    assert_nil Mia::NarrationClaims.rejection_reason("Your saved plan leaves room for bills.")
    assert_nil Mia::NarrationClaims.rejection_reason("Your saved Everyday checking balance is unknown.")
  end

  test "manual merchant input keeps words that resemble a category suffix" do
    category = household.budget_categories.active.find_by!(stack_key: "discretionary")
    category.update!(name: "Groceries")
    result = HouseholdFinance::Operations::Runner.new(household, user: @user).run(operation_key: "transaction.draft.create", input: { merchant: "Market for Groceries", amount_cents: 1200, occurred_on: Date.current.iso8601, source_type: "manual_ui" }, idempotency_key: SecureRandom.uuid, source: "manual")
    assert_equal "Market for Groceries", result.subject.merchant
  end

  test "pattern ranking and model validation qualify flexible merchant totals" do
    narrator = SpendingPatterns::Narrator.new(user_message: "What spending patterns do you see?", persona: Mia::Persona.neutral,
      answer_packet: { fallback_response: "I only see purchases for Oct: Ross ($100) was your biggest flexible spending stop. Review a purchase. Would you feel comfortable looking at it?", verified_facts: { merchants: [ { label: "Ross", total_cents: 10000 } ], category_names: [], choices: [], months_with_purchases: [ "Oct" ], missing_months: true } })
    assert narrator.send(:patterns_rejection, "I only see purchases for Oct: Ross ($100) was your biggest spending stop. Review a purchase. Would you feel comfortable looking at it?")
  end

  test "recurring explicit buys stay monthly commitments instead of one time comparisons" do
    [ "Can I buy a $120 monthly gym membership?", "Should I purchase a $50 per month subscription?" ].each do |message|
      answer = HouseholdFinance::MiaCoachAnswerer.new(household, message).call.to_s
      assert_match(/recurring|each month|every month|monthly commitment/, answer, message)
      refute_match(/The \$.*purchase.*would leave/, answer, message)
    end
  end

  test "legacy purse guidance uses a corrected price in the current turn" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Can I buy a $500 purse? No, it costs $600", annual_budget_manager: manager).call
    assert_includes answer, "$600 purse"
    refute_includes answer, "$500 purse"
  end

  private

  def household
    return @household if @household

    @user = User.create!(clerk_id: "late_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz", primary_goal: "Save", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900", debt_payment: "95").call
    @household
  end

  def manager = HouseholdFinance::AnnualBudgetManager.new(household)

  def narrator(kind, message = "Can I afford a $300 stroller?")
    HouseholdFinance::MiaNarrator.new(user_message: message, answer_packet: { kind: kind, write_state: "no_write", fallback_response: "Keep the verified answer." })
  end
end
