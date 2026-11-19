require "test_helper"
require_relative "../support/participant_reader_test_support"

# A real-data test (Nov 18 2026): income, subscriptions and "is our
# budget realistic?" each got a spending answer or a deflection.
class ApiV1MiaAnswersTheQuestionTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport

  READINGS = {
    "model off" => nil,
    "spending patterns" => "spending_patterns",
    "month balance" => "month_balance",
    "none" => "none"
  }.freeze

  setup do
    # The plan starts in July, when the household is set up; the questions come in August.
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!(with_history: true)
    travel_to Time.zone.local(2026, 8, 15, 12)
  end
  teardown { travel_back }

  test "how much came in is answered with planned income under every reading and never with spending" do
    [ "How much came in last month?", "How much money came in in July?", "How much did we earn last month?" ].each do |message|
      each_reading(message) do |label|
        assert_includes reply, "Your plan counts $8,000 coming in for July 2026", "#{label}: #{message}"
        assert_includes reply, "not a total of the deposits on your statements", "#{label}: #{message}"
        refute_match(/you spent|you’ve spent|flexible spending/i, reply, "#{label}: #{message}")
      end
    end
  end

  test "a purchase reported with an income question is not swallowed by the income answer" do
    post_message("Bought diapers for $45 at Payless today. How much came in this month?")
    refute_includes reply, "Your plan counts"
    assert_includes reply, "$45"
  end

  test "income for a year adds the planned months, and a week says the plan is monthly" do
    post_message("How much have we brought in this year?")
    assert_includes reply, "Your plan counts $16,000 coming in from July to August 2026."
    post_message("How much did we earn last year?")
    assert_includes reply, "Your plan doesn’t have income for 2025."
    post_message("How much came in this week?")
    assert_includes reply, "I only have your income by month, not by day or week. Your plan counts $8,000 coming in for August 2026."
  end

  test "a month she names or calls this month wins over so far and a year beside it" do
    post_message("How much has come in so far this month?")
    assert_includes reply, "Your plan counts $8,000 coming in for August 2026."
    post_message("How much came in so far in July?")
    assert_includes reply, "Your plan counts $8,000 coming in for July 2026."
    post_message("How much came in in December last year?")
    assert_includes reply, "I don’t have income for December 2025."
    post_message("How much came in in 2026-07?")
    assert_includes reply, "Your plan counts $8,000 coming in for July 2026."
  end

  test "money in versus money out is not an income-only question" do
    post_message("How much came in vs went out last month?")
    refute_includes reply, "Your plan counts"
  end

  test "income before the plan starts says so instead of reporting spending" do
    post_message("How much came in in June?")
    assert_includes reply, "Your plan starts in July 2026, so I don’t have income for June 2026."
    refute_match(/you spent/i, reply)
  end

  test "saved income questions keep their detailed answer and never become spending" do
    each_reading("What's my income this month?") do |label|
      assert_includes reply, "Saved household income for August 2026", label
      refute_match(/flexible spending|you spent/i, reply, label)
    end
  end

  test "subscriptions list what repeats monthly from reviewed purchases, with no cut estimate" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    streaming = manager.create_category!(name: "Streaming", stack_key: "discretionary", monthly_amount: 40)
    [ [ 5, 1899 ], [ 6, 2149 ], [ 7, 2149 ] ].each do |month, cents|
      confirmed(manager, streaming, Date.new(2026, month, 23), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/23 Disney Plus 888-····4242 CA S*····8141 Card 7302", cents)
    end
    [ 5, 6, 7 ].each { |month| confirmed(manager, streaming, Date.new(2026, month, 8), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/08 Google Youtubeprem 650-····1111 CA S*····7788 Card 7302", 1399) }
    before = financial_counts
    [ "What subscriptions am I paying for?", "Do I have any subscriptions?" ].each do |message|
      each_reading(message) do |label|
        assert_includes reply, "From May to Jul, these repeat about monthly at a steady price, so they look like subscriptions: Disney Plus ($21.49) and Google Youtubeprem ($13.99).", "#{label}: #{message}"
        assert_includes reply, "Together that’s about $35.48 a month.", label
        assert_includes reply, "another card or account", label
        refute_match(/Spending half|could free|Jamaican Grill|Recurring Payment|S\*/, reply, label)
        assert_nil response.parsed_body["mia_action_draft"]
        assert_nil response.parsed_body["transaction_draft"]
      end
    end
    assert_equal before, financial_counts
  end

  test "subscription questions with a time word, and protected autopay, read correctly" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    streaming = manager.create_category!(name: "Streaming", stack_key: "discretionary", monthly_amount: 40)
    childcare = manager.create_category!(name: "Childcare", stack_key: "non_discretionary", monthly_amount: 800)
    [ 5, 6, 7 ].each do |month|
      confirmed(manager, streaming, Date.new(2026, month, 8), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/08 Google Youtubeprem 650-····1111 CA S*····7788 Card 7302", 1399)
      confirmed(manager, childcare, Date.new(2026, month, 1), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/01 Little Learners Daycare", 80_000)
    end
    insurance = manager.create_category!(name: "Insurance", stack_key: "non_discretionary", monthly_amount: 300)
    [ 5, 6, 7 ].each { |month| confirmed(manager, insurance, Date.new(2026, month, 1), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/01 Island Health Plan", 30_000) }
    [ "What subscriptions do we pay for every month?", "How much do we pay in subscriptions a month?", "Am I paying for too many subscriptions?",
      "What streaming services am I paying for?", "Which subscription should I cancel?", "Check my subscriptions" ].each do |message|
      post_message(message)
      assert_includes reply, "so it looks like a subscription: Google Youtubeprem ($13.99).", message
      refute_match(/Daycare|Health Plan/, reply, "protected autopay is never a subscription to reconsider")
    end
  end

  test "a membership mentioned in passing is not a subscriptions question" do
    post_message("How are we doing this month after cancelling the gym membership?")
    assert_match(/\AYour plan (?:leaves about|is short by)/, reply)
    post_message("What do you think about a Costco membership?")
    refute_includes reply, "repeats every month"
  end

  test "subscriptions with none found say what was checked" do
    each_reading("What subscriptions am I paying for?") do |label|
      assert_includes reply, "From May to Jul, I don’t see a charge in your reviewed purchases that repeats every month at a steady price.", label
      refute_match(/one step at a time|Spending half/i, reply, label)
    end
  end

  test "is our budget realistic gets the month's plan, not a deflection" do
    [ "Our family is growing. Is our budget realistic?", "Is our budget realistic?", "Does our plan work?" ].each do |message|
      each_reading(message) do |label|
        assert_match(/\AYour plan (?:leaves about|is short by) \$[\d,]+ for August 2026/, reply, "#{label}: #{message}")
        refute_match(/one step at a time|You choose what we work on next|flexible spending stop/i, reply, "#{label}: #{message}")
      end
    end
  end

  private

  def each_reading(message)
    READINGS.each do |label, intent|
      if intent
        with_participant_reader_response({ care: "none", reply_intent: intent, question: true, correction: false, facts: [], setup_answer: { field: "none", value: "" }, spending_preferences: [] }) do
          post_message(message)
          yield label
        end
      else
        post_message(message)
        yield label
      end
    end
  end

  def confirmed(manager, category, occurred_on, merchant, cents)
    transaction = @household.household_transactions.create!(budget_period: manager.current_period_for(occurred_on), occurred_on: occurred_on,
      merchant: merchant, total_amount_cents: cents, source_type: "statement", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: cents)
  end

  def financial_counts
    [ @household.household_transactions.count, @household.transaction_drafts.count, @household.mia_action_drafts.count, @household.budget_categories.count ]
  end

  def post_message(message)
    post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 8 }, headers: {
      "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test"
    }, as: :json
    assert_response :created
  end

  def reply
    response.parsed_body.dig("assistant_message", "content")
  end
end
