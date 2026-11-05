require "test_helper"

class MiaReviewRoundTwoTest < ActiveSupport::TestCase
  setup { travel_to Time.zone.local(2026, 5, 28, 12) }
  teardown { travel_back }

  test "food support requires acknowledgment and a concrete step to get food today" do
    [ "Food is a priority. Talk to your coach today. Does everyone have enough food today?",
      "You skipped meals so the kids could eat. Talk to your coach today. Does everyone have enough food today?",
      "Food is a priority. Please get food for yourself today and talk to your coach. Does everyone have enough food today?" ].each do |content|
      assert_equal :food_support_missing, food_narrator.send(:narration_rejection_reason, content), content
      subject = food_narrator
      subject.define_singleton_method(:openrouter_response) { content }
      assert_equal food_fallback, subject.call
    end
  end

  test "recorded live skipped meal replies and deterministic support remain accepted" do
    [ "You skipping meals so the kids could eat tells me how heavy this is right now, and you need food too. Please get food for yourself today, and reach out to your coach or someone you trust about getting food and checking what local food help is available. Do you have enough food for everyone in your home today, including you?",
      "You skipped meals so the kids could eat, and that tells me how tight this week has been. You need to eat too, so please get food for yourself today and talk with your coach or someone you trust about it. Food comes ahead of savings, extra debt payments, and the stroller decision. Does everyone, including you, have enough food today?", food_fallback ].each do |content|
      assert_nil food_narrator.send(:narration_rejection_reason, content), content
      subject = food_narrator
      subject.define_singleton_method(:openrouter_response) { content }
      assert_equal content, subject.call
    end
  end

  [ "Don't get food today", "Do not get food today", "You can skip eating today", "No need to get food", "You don't need to eat today", "You should not find food today" ].each do |instruction|
    test "negated food instruction #{instruction} falls back even beside a valid food step" do
      content = "You skipped meals so your kids could eat. #{instruction}; talk with your coach. Please get food today. Does everyone have enough food today?"
      subject = food_narrator
      subject.define_singleton_method(:openrouter_response) { content }
      assert_equal food_fallback, subject.call
      assert_equal :food_support_missing, subject.send(:narration_rejection_reason, content)
    end
  end

  [ "I make $4,500 a month, can I afford a $300 stroller?", "My income is $4,500, can I afford a $300 stroller?",
    "I earn $4,500 a month. Can I buy a $300 stroller?", "My income is $4,500 a month. Can I buy a $300 stroller?",
    "I make $4,500 a month and can I buy a $300 stroller?" ].each_with_index do |message, index|
    test "complete purchase answer uses the price beside income phrasing #{index}" do
      subject = answerer(message)
      assert_nil subject.send(:recurring_purchase_answer)
      assert_equal answerer("Can I afford a $300 stroller?").call, subject.call
    end
  end

  test "purchase impact uses its purchase clause instead of earlier income" do
    assert_equal answerer("Can I buy a $300 stroller and how would it affect runway?").call,
      answerer("I make $4,500 a month. Can I buy a $300 stroller and how would it affect runway?").call
  end

  test "purchase account coverage uses the price instead of earlier income" do
    question = "Can I buy a $300 stroller, and which account could fund it?"
    assert_equal answerer(question).call, answerer("My income is $4,500. #{question}").call
  end

  test "purse price binding and compound purchase debt roles ignore earlier income" do
    [ "Can I buy a $300 purse?", "Can I buy a $300 stroller and make a $200 extra credit card payment?" ].each do |question|
      assert_equal answerer(question).call, answerer("My income is $4,500. #{question}").call
    end
  end

  test "income and balances cannot price an unpriced or ambiguous purchase" do
    [ "I make $4,500 a month. Can I afford a stroller?", "My income is $4,500, can I afford a stroller?",
      "Can I buy a stroller with $4,500 income and $2,000 in checking?", "Can I buy a $300 or $400 stroller?" ].each do |message|
      assert_match(/What does the item cost|Which purchase price/, answerer(message).call, message)
    end
  end

  test "monthly income outside a purchase clause cannot suppress purchase intent or create recurrence" do
    [ "I earn $4,500 a month. Can I buy a $300 stroller?", "Can I buy a $300 stroller? My monthly income is $4,500.",
      "I earn $4,500 a month, and can I buy a $300 stroller?" ].each do |message|
      subject = answerer(message)
      assert subject.send(:purchase_question?), message
      assert_nil subject.send(:recurring_purchase_answer), message
    end
  end

  test "saving or quitting in another clause cannot suppress a purchase" do
    [ "I want to save for emergencies. Can I buy a $300 stroller?", "Can I buy a $300 stroller? I want to quit my job next year.",
      "I want to save for emergencies, but can I buy a $300 stroller?" ].each do |message|
      assert answerer(message).send(:purchase_question?), message
    end
  end

  test "saving and quitting within their own clause are not purchases" do
    [ "Can I afford to save $300?", "Can I afford to quit my job for $300?" ].each do |message|
      refute answerer(message).send(:purchase_question?), message
      refute_match(/The \$.*purchase/i, answerer(message).call.to_s, message)
    end
  end

  test "monthly without a recurring purchase amount cannot create a commitment" do
    subject = answerer("Can I buy a monthly planner to save receipts?")
    assert_nil subject.send(:recurring_purchase_answer)
    assert subject.send(:purchase_question?)
  end

  test "monthly purchase amounts stay recurring only inside their purchase clause" do
    [ "Can I buy a $120 monthly gym membership?", "Should I purchase a $50 per month subscription?",
      "Can I buy a gym membership for $120 every month?", "Can I buy a gym membership monthly for $120?" ].each do |message|
      assert_includes answerer(message).send(:recurring_purchase_answer).to_s, "recurring monthly commitment", message
    end
  end

  test "a current purchase clause takes precedence over prior followup purchases" do
    context = { active_topic: { type: "coaching", title: "Purchase decision", latest_user_context: "Can I buy a $300 stroller? $200 of that is a gift card." } }
    followup = HouseholdFinance::ConversationFollowupResolver.new("Can I buy a $120 monthly gym membership?", conversation_context: context).call
    assert followup.follow_up?
    assert_includes answerer(followup.message).call, "recurring monthly commitment"
  end

  test "a complete current purchase answer cannot reuse the prior followup price" do
    context = { active_topic: { type: "coaching", title: "Purchase decision", latest_user_context: "Can I buy a $300 stroller?" } }
    followup = HouseholdFinance::ConversationFollowupResolver.new("Can I buy a $200 stroller?", conversation_context: context).call
    assert followup.follow_up?
    assert_equal answerer("Can I buy a $200 stroller?").call, answerer(followup.message).call
  end

  { "tomorrow" => "May 2026", "next week" => "June 2026", "next year" => "May 2027" }.each do |timing, label|
    test "purchase timing resolves #{timing} before the selected period default" do
      assert_includes answerer("Can I buy a $300 stroller #{timing}?", reference_month: 8).send(:purchase_plan_answer), label
    end
  end

  test "tomorrow crosses month and year boundaries" do
    travel_to Time.zone.local(2026, 12, 31, 12)
    assert_includes answerer("Can I buy a $300 stroller tomorrow?").send(:purchase_plan_answer), "January 2027"
  end

  test "timing before the purchase clause survives scoped price selection" do
    assert_includes answerer("Next month, can I buy a $300 stroller?", reference_month: 8).call, "June 2026"
  end

  test "skipping meals to eat out is not food insecurity" do
    refute HouseholdFinance::MoneyMovementText.food_insecurity?("I skip meals so I can eat out tonight")
  end

  test "feeding other people preserves the missed meal hardship" do
    [ "I skip meals to feed my kids", "I've been skipping meals so the kids could eat", "I skip meals so my husband can eat",
      "I missed lunch so my children could eat, but my food budget is empty" ].each do |message|
      assert HouseholdFinance::MoneyMovementText.food_insecurity?(message), message
    end
  end

  test "a dollar amount with gift card context is not a price correction" do
    message = "Can I buy a $300 stroller? $200 of that is a gift card."
    assert_equal "Can I buy a $300 stroller?", HouseholdFinance::PurchaseQuestionText.for_comparison(message).text
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "").deterministic_scenario_result
    assert_equal "300", result.read_only_plan[:items].first[:amount]
  end

  test "bare dollar amounts and explicit corrections still replace the price" do
    [ "$200", "$200.", "$200, please", "Actually, $200!", "No, it costs $200" ].each do |correction|
      result = HouseholdFinance::PurchaseQuestionText.for_comparison("Can I buy a $300 stroller? #{correction}")
      assert_equal "Can I buy a $200 stroller?", result.text, correction
      refute result.needs_clarification, correction
    end
  end

  test "polite shorthand correction reaches both complete purchase answers" do
    message = "Can I buy a $300 stroller? $200, please"
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "").deterministic_scenario_result
    assert_equal "200", result.read_only_plan[:items].first[:amount]
    assert_equal answerer("Can I buy a $200 stroller?").call, answerer(message).call
  end

  test "a correction followed by an unclear price asks instead of guessing" do
    result = HouseholdFinance::PurchaseQuestionText.for_comparison("Can I buy a $300 stroller? Actually, $200! $250 with tax.")
    assert result.needs_clarification
  end

  test "naming the paying account keeps the stated price, while a stated balance does not become one" do
    priced = answerer("Can I buy a $300 stroller with my checking account?").call
    assert_equal answerer("Can I buy a $300 stroller?").call.to_s[/\$[\d,]+/], priced.to_s[/\$[\d,]+/]
    assert_includes priced, "$300"
    refute_includes answerer("I have $500 in checking. Can I buy a stroller?").call.to_s, "$500 purchase"
  end

  test "unrecognized later dollar fragments clarify rather than retain the earlier price" do
    result = HouseholdFinance::PurchaseQuestionText.for_comparison("Can I buy a $300 stroller? $200 maybe, or $250")
    assert result.needs_clarification
  end

  test "one flexible category uses singular grammar" do
    HouseholdFinance::AnnualBudgetManager.new(household).plan_data
    period = household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 4, 1))
    category = household.budget_categories.active.find_by!(stack_key: "discretionary")
    category.update!(name: "Dining Out")
    transaction = household.household_transactions.create!(budget_period: period, occurred_on: Date.new(2026, 4, 15), merchant: "Cafe", total_amount_cents: 1000, source_type: "statement", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1000)
    answer = SpendingPatterns::Answerer.new(household: household, message: "What spending patterns do you see?", persona: Mia::Persona.neutral, history: [], approved_content: []).call
    assert_includes answer, "Your largest flexible spending category was Dining Out."
  end

  [ "biggest overall total", "biggest overall flexible spending stop", "largest overall recorded merchant amount", "top overall spending amount" ].each do |ranking|
    test "patterns reject #{ranking}" do
      assert_equal :unqualified_flexible_pattern, patterns_narrator.send(:patterns_rejection, pattern_reference.sub("biggest flexible spending stop", ranking))
    end
  end

  test "plain flexible ranking and fallback wording remain accepted" do
    assert_nil patterns_narrator.send(:patterns_rejection, pattern_reference)
    subject = patterns_narrator
    content = pattern_reference
    subject.define_singleton_method(:openrouter_response) { content }
    assert_equal pattern_reference, subject.call
  end

  private

  def household
    return @household if @household

    user = User.create!(clerk_id: "review2_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz", primary_goal: "Save", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900", debt_payment: "95").call
    @household
  end

  def answerer(message, reference_month: 5)
    HouseholdFinance::MiaCoachAnswerer.new(household, message, reference_month: reference_month)
  end

  def food_fallback
    HouseholdFinance::MiaCoachAnswerer.new(household, "I've been skipping meals so the kids could eat").call
  end

  def food_narrator
    HouseholdFinance::MiaNarrator.new(user_message: "I've been skipping meals so the kids could eat", api_key: "recorded-only",
      answer_packet: { kind: "coaching", write_state: "no_write", fallback_response: food_fallback })
  end

  def pattern_reference
    "I only see purchases for Apr: Cafe ($10) was your biggest flexible spending stop. Review a purchase. Would you feel comfortable looking at it?"
  end

  def patterns_narrator
    SpendingPatterns::Narrator.new(user_message: "What spending patterns do you see?", persona: Mia::Persona.neutral, api_key: "recorded-only",
      answer_packet: { fallback_response: pattern_reference, verified_facts: { merchants: [ { label: "Cafe", total_cents: 1000 } ], choices: [], months_with_purchases: [ "Apr" ], missing_months: true } })
  end
end
