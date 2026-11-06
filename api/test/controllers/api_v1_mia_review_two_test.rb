require "test_helper"

class ApiV1MiaReviewTwoTest < ActionDispatch::IntegrationTest
  setup do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
  end
  teardown { travel_back }

  ROUTING_CASES = {
    "I can't afford food. I stayed under budget; can I buy a purse?" => [ :hardship, "getting food today" ],
    "I can't pay rent. How am I doing this month?" => [ :hardship, "landlord" ],
    "I cannot buy medicine. I stayed under my budget." => [ :hardship, "food, housing, utilities and medicine" ],
    "I stayed under my budget. I skipped lunch to save for the challenge" => [ :essential_skip, "Please do not skip food" ],
    "I skipped lunch to save. How am I doing this month?" => [ :essential_skip, "Please do not skip food" ],
    "I feel stressed about money. How am I doing this month?" => [ :month, "July 2026" ],
    "I stayed under my budget. How am I doing this month?" => [ :month, "July 2026" ],
    "I stayed under my budget. Should I buy a purse?" => [ :purchase, "purse" ],
    "I skipped lunch to save. Should I order takeout?" => [ :essential_skip, "Please do not skip food" ],
    "I feel stressed. Rename Dining Out category to Meals." => [ :write, nil ],
    "I'm embarrassed I went to Ross again" => [ :reflective, "Ross" ],
    "Can I buy a bag for school?" => [ :purchase, "baseline need" ]
  }.freeze

  ROUTING_CASES.each do |message, (priority, expected)|
      test "shared routing: #{message}" do
      assert_equal priority, HouseholdFinance::MiaCoachAnswerer.routing_priority(message)
      next unless expected

      post_message(message)
      assert_includes reply, expected
      refute response.parsed_body["transaction_draft"]
      refute response.parsed_body["mia_action_draft"]
      refute_match(/you kept|what worked/i, reply) if priority.in?(%i[hardship essential_skip])
    end
  end

  test "R2 an unsupported rent edit still answers the known current month without treating its amount as a year" do
    post_message("change my rent to 2000, how much do i have left")
    assert_includes reply, "July 2026"
    assert_includes reply, "$1,890"
    refute_includes reply, "2000"
    assert_equal 2026, response.parsed_body.dig("month_answer", "year")
  end

  test "feeling plus month keeps the feeling short and the requested figures primary" do
    post_message("I feel stressed about money. How am I doing this month?")
    assert_match(/\AThat sounds stressful;/, reply)
    assert_includes reply, "$1,890"
    assert_equal 1, reply.scan(/not a bank balance/).length
  end

  test "month plus current salary writes retains the review and exact amount" do
    [ "How am I doing this month — and change my salary to $6,400",
      "How am I doing this month? My salary is $6,400 now" ].each do |message|
      @household.mia_action_drafts.destroy_all
      post_message(message)
      assert response.parsed_body["mia_action_draft"], response.parsed_body.inspect
      assert_match(/\AYour plan leaves/, reply)
      assert_includes reply, "July 2026"
      assert_equal 800000, response.parsed_body.dig("month_answer", "money_in_cents")
      assert_equal 189000, response.parsed_body.dig("month_answer", "plan_left_cents")
      assert_equal 4, reply.split(/(?<=[.!?])\s+/).length
      assert_includes reply, "$6,400"
      assert_equal 800000, @household.income_sources.find_by!(source_type: "job").amount_cents
    end
  end

  test "month leads a purchase review while the reported purchase stays pending" do
    post_message("I spent $60 at Ross today. How am I doing this month?")
    assert_match(/\AYour plan leaves/, reply)
    assert_includes reply, "pending Ross review for $60"
    assert_equal 6000, response.parsed_body.dig("transaction_draft", "amount_cents")
    assert_equal "pending", response.parsed_body.dig("transaction_draft", "status")
    assert_equal 4500, response.parsed_body.dig("month_answer", "spent_so_far_cents")
    assert_equal 3, reply.split(/(?<=[.!?])\s+/).length
  end

  test "unrelated turns never compute a month packet" do
    original = HouseholdFinance::MiaMonthAnswer.method(:for_question)
    HouseholdFinance::MiaMonthAnswer.define_singleton_method(:for_question) { |*| raise "unexpected month scan" }
    post_message("I went to Ross again")
    assert_nil response.parsed_body["month_answer"]
    assert_includes reply, "Ross"
  ensure
    HouseholdFinance::MiaMonthAnswer.define_singleton_method(:for_question, original)
  end

  test "month facts reuse one answer for narration and response metadata" do
    original = HouseholdFinance::MiaMonthAnswer.method(:for_question)
    calls = 0
    HouseholdFinance::MiaMonthAnswer.define_singleton_method(:for_question) do |*args, **kwargs|
      calls += 1
      original.call(*args, **kwargs)
    end
    post_message("How am I doing this month?")
    assert_equal 1, calls
    assert_equal 189000, response.parsed_body.dig("month_answer", "plan_left_cents")
  ensure
    HouseholdFinance::MiaMonthAnswer.define_singleton_method(:for_question, original)
  end

  test "optional month facts failing cannot fail a persisted chat turn" do
    original = HouseholdFinance::MiaMonthAnswer.instance_method(:call)
    HouseholdFinance::MiaMonthAnswer.define_method(:call) { raise "synthetic snapshot unavailable" }
    assert_difference -> { ChatMessage.count }, 2 do
      post_message("How am I doing this month?")
    end
    assert_nil response.parsed_body["month_answer"]
    assert_includes reply, "try your month question again"
  ensure
    HouseholdFinance::MiaMonthAnswer.define_method(:call, original)
  end

  test "a failed month rendering keeps the requested write review available" do
    original = HouseholdFinance::MiaMonthAnswer.instance_method(:response)
    HouseholdFinance::MiaMonthAnswer.define_method(:response) { |**| raise "synthetic rendering unavailable" }
    post_message("How am I doing this month — and change my salary to $6,400")
    assert response.parsed_body["mia_action_draft"]
    assert_includes reply, "$6,400"
    assert_equal 800000, @household.income_sources.find_by!(source_type: "job").amount_cents
  ensure
    HouseholdFinance::MiaMonthAnswer.define_method(:response, original)
  end

  test "invalid numeric month asks without loading a substituted plan" do
    original = HouseholdFinance::AnnualBudgetManager.method(:new)
    HouseholdFinance::AnnualBudgetManager.define_singleton_method(:new) { |*| raise "must not load plan" }
    answer = HouseholdFinance::MiaMonthAnswer.for_question(@household, "How am I doing in 2026-13?")
    assert_nil answer.call[:spent_so_far_cents]
    assert_includes answer.response, "Which month and year"
  ensure
    HouseholdFinance::AnnualBudgetManager.define_singleton_method(:new, original)
  end

  test "truncated pending list containing selected month rows still has unknown totals" do
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).read_only_plan_data
    plan[:pending_transaction_drafts] = [ { occurred_on: "2026-07-10", amount_cents: 1234 } ]
    plan[:pending_transaction_drafts_meta] = { truncated: true, total_count: 501, returned_count: 500 }
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: 7)
    assert_nil answer.call[:pending_count]
    assert_nil answer.call[:pending_cents]
    assert_includes answer.response, "review list is incomplete"
  end

  test "unknown plan opening names the requested period without a cash hedge" do
    @household.update!(created_at: Date.new(2025, 1, 1))
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2025).read_only_plan_data.merge(plan_available: false)
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: 9)
    assert_includes answer.response, "2025 plan is not set up yet"
    assert_includes answer.response, "September 2025"
    refute_match(/not a bank balance/, answer.response)
  end

  test "embarrassed repeated activities never borrow dinner details" do
    [ "I'm embarrassed I went to Ross again", "I'm ashamed I bought coffee again", "I'm ashamed I keep buying things" ].each do |message|
      post_message(message)
      assert_includes reply, "does not make you a failure"
      refute_match(/takeout|dinner|meal|store visit without an amount|damage/i, reply)
    end
  end

  test "checking balance is not a purse price but explicit purchase price is" do
    post_message("I have $500 in checking; should I buy a purse?")
    assert_includes reply, "What does the purse cost"
    refute_includes reply, "$500"
    post_message("I have $500 in checking; should I buy a purse for $60?")
    assert_includes reply, "$60 purse"
    refute_includes reply, "$500 purse"
    post_message("I have $500 in checking; should I buy a purse at Ross for $60?")
    assert_includes reply, "$60 purse"
    [ "I have $500 in checking; can I spend $60 on a handbag if it is on sale?",
      "I have $500 in checking; should I pay $60 for the purse?" ].each do |message|
      post_message(message)
      assert_includes reply, "$60 purse"
      refute_includes reply, "$500 purse"
    end
  end

  test "school and work purpose is essential but incidental timing is discretionary" do
    post_message("Can I buy a bag for work?")
    assert_includes reply, "baseline need"
    post_message("Can I buy a purse after work?")
    assert_includes reply, "What does the purse cost"
    refute_includes reply, "baseline need"
  end

  test "third party historical hypothetical and discretionary food do not become household hardship" do
    [ "My friend can't afford groceries, can I lend her $50?",
      "Last year we couldn't afford groceries but now we're doing better",
      "What if we can't afford groceries next month?",
      "I can't afford groceries at Payless anymore so I switched to Costco" ].each do |message|
      refute_equal :hardship, HouseholdFinance::MiaCoachAnswerer.routing_priority(message), message
    end
  end

  test "rename proposal reviews details and clearly remains unapplied" do
    post_message("Rename Dining Out category to Meals")
    assert response.parsed_body["mia_action_draft"], response.parsed_body.inspect
    assert_includes reply, "Check the details"
    assert_includes reply, "nothing changes until you apply"
    refute_match(/amount and timing/, reply)
    assert @household.budget_categories.exists?(name: "Dining Out")
    refute @household.budget_categories.exists?(name: "Meals")
  end

  test "existing category followup persists the canonical category without creating an alias" do
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    count = @household.budget_categories.count
    post_message("Put it under the fixed ESSENTIALS category please!")
    assert response.parsed_body["transaction_draft"], response.parsed_body.inspect
    draft = @household.transaction_drafts.pending.sole.reload
    assert_equal category.id, draft.transaction_draft_splits.sole.budget_category_id
    assert_equal count, @household.budget_categories.count
    refute @household.budget_categories.exists?(name: "the fixed ESSENTIALS")
  end

  private

  def post_message(message)
    post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 7 }, headers: {
      "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test"
    }, as: :json
    assert_response :created
  end

  def reply
    response.parsed_body.dig("assistant_message", "content")
  end
end
