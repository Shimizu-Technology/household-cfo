require "test_helper"

class ApiV1MiaMelCoachingTest < ActionDispatch::IntegrationTest
  setup do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
  end
  teardown { travel_back }

  test "wins repeated habits and hard days coach without creating purchases" do
    {
      "I stayed under my grocery budget for the whole week!" => "You kept",
      "I stuck to my food budget." => "You kept",
      "I went to Ross again today. That’s the third time this month." => "Ross",
      "I keep buying takeout when I get home tired." => "repeat stop",
      "I'm so stressed about money this week" => "heavy week"
    }.each do |message, expected|
      assert_no_difference [ -> { @household.transaction_drafts.count }, -> { @household.mia_action_drafts.count } ] do
        post_message(message)
      end
      assert_includes reply, expected, message
      refute_match(/how much did you spend|budget stack|not have enough approved data|readiness is Red/i, reply)
    end
  end

  test "clear reported amount remains a purchase even with feelings" do
    post_message("I spent $12 at Payless today. I feel stressed.")
    assert response.parsed_body["transaction_draft"], response.parsed_body.slice("transaction_draft", "assistant_message").inspect
    draft = response.parsed_body.fetch("transaction_draft")
    assert_equal "Payless", draft.fetch("merchant")
    assert_equal 1200, draft.fetch("amount_cents")
    assert_equal "pending", draft.fetch("status")
  end

  test "incurred spending after a repeated habit still creates a purchase review" do
    post_message("I went to Ross again and spent $60 today")
    assert response.parsed_body["transaction_draft"], response.parsed_body.slice("transaction_draft", "assistant_message").inspect
    draft = response.parsed_body.fetch("transaction_draft")
    assert_equal "Ross", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
    assert_equal "pending", draft.fetch("status")
  end

  { "October 1, 2025" => "2025-10-01", "2026-06-01" => "2026-06-01", "yesterday" => "2026-07-14" }.each do |phrase, expected|
    test "purchase continuation preserves #{phrase}" do
      @household.transaction_drafts.destroy_all
      post_message("I spent money at Ross today")
      post_message("It was $60 on #{phrase}")
      assert response.parsed_body["transaction_draft"], response.parsed_body.slice("transaction_draft", "assistant_message").inspect
      draft = response.parsed_body.fetch("transaction_draft")
      assert_equal "Ross", draft.fetch("merchant")
      assert_equal expected, draft.fetch("occurred_on")
    end
  end

  test "an unresolved purchase continuation day asks instead of substituting today" do
    @household.transaction_drafts.destroy_all
    post_message("I spent money at Ross today")
    assert_no_difference -> { @household.transaction_drafts.count } do
      post_message("It was $60 on February 30")
    end
    assert_nil response.parsed_body["transaction_draft"]
    assert_includes reply, "Which past day"
  end

  test "month overview honors a named month and year over the open budget period" do
    post "/api/v1/mia/messages", params: { message: "How am I doing in September 2026?", year: 2025, month: 1 },
      headers: { "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test" }, as: :json
    assert_response :created
    assert_equal 2026, response.parsed_body.dig("month_answer", "year")
    assert_equal 9, response.parsed_body.dig("month_answer", "month")
    assert_includes reply, "September 2026"
  end

  test "month answer distinguishes positive plan from cushion and agrees with API figures" do
    post_message("How am I doing this month?")
    facts = response.parsed_body.fetch("month_answer")
    assert_equal 800_000, facts.fetch("money_in_cents")
    assert_equal facts.fetch("money_in_cents") - facts.fetch("planned_out_cents"), facts.fetch("plan_left_cents")
    assert_equal 4500, facts.fetch("spent_so_far_cents")
    assert_equal 2200, facts.fetch("pending_cents")
    assert_equal "red", facts.fetch("readiness_tone")
    assert_includes reply, "plan leaves"
    assert_includes reply, "build your cushion"
    refute_match(/safe-to-spend|not have enough approved data/, reply)
  end

  test "unknown plan figures remain unknown" do
    BudgetAllocation.joins(:budget_category).where(budget_categories: { household_id: @household.id }).order(:budget_period_id).first.destroy!
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).read_only_plan_data
    facts = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: 1).call
    assert_nil facts.fetch(:planned_out_cents)
    assert_nil facts.fetch(:plan_left_cents)
    assert_nil facts.fetch(:safe_to_spend_cents)
  end

  test "present salary change reviews this month forward and preserves earlier income after apply" do
    source = @household.income_sources.find_by!(source_type: "job")
    before = HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 6, 1))
    post_message("My salary is $6,400 now")
    draft = @household.mia_action_drafts.order(:id).last
    assert draft, response.parsed_body.slice("transaction_draft", "assistant_message").inspect
    item = draft.mia_action_items.sole
    assert_equal "upsert_income_schedule_entry", item.action_type
    assert_equal "2026-07-01", item.payload.fetch("effective_on")
    assert_includes item.description, "July 2026"
    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert result.success?, result.inspect
    source.reload
    assert_equal before, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 6, 1))
    assert_equal 640_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 7, 1))
  end

  test "new category keeps the purchase pending and creates category only when confirmed" do
    assert_no_difference -> { @household.budget_categories.count } do
      post_message("Spent $12 at Payless on cigarettes. Put it in a new Cigarettes category.")
    end
    draft = @household.transaction_drafts.find(response.parsed_body.dig("transaction_draft", "id"))
    assert_equal "Cigarettes", draft.transaction_draft_splits.sole.category_name
    assert_equal 1200, draft.total_amount_cents
    assert_equal "pending", draft.status
    assert_includes reply, "new category will be added"
    assert_nil @household.budget_categories.find_by(name: "Cigarettes")
    post "/api/v1/transaction_drafts/#{draft.id}/confirm", params: {}, headers: {
      "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test",
      "Idempotency-Key" => SecureRandom.uuid
    }, as: :json
    assert_response :success
    assert_equal "Cigarettes", draft.reload.confirmed_transaction.transaction_splits.sole.budget_category.name
    status = response.parsed_body.dig("workspace", "mia", "messages").last.fetch("content")
    assert_includes status, "in Cigarettes"
    refute_includes status, "Uncategorized"
  end

  test "category followup reuses the pending amount and merchant" do
    post_message("I spent $12 at Payless today")
    @household.transaction_drafts.where.not(id: response.parsed_body.dig("transaction_draft", "id")).destroy_all
    post_message("Put it under Cigarettes")
    draft = @household.transaction_drafts.pending.sole
    assert_equal "Payless", draft.merchant
    assert_equal 1200, draft.total_amount_cents
    assert_equal "Cigarettes", draft.transaction_draft_splits.sole.category_name
    assert_nil @household.budget_categories.find_by(name: "Cigarettes")
  end

  test "purchase clarification uses participant merchant from earlier turn without borrowing assistant amounts" do
    @household.transaction_drafts.destroy_all
    post_message("I spent money at Ross today")
    post_message("It was $60")
    draft = response.parsed_body["transaction_draft"]
    assert draft, response.parsed_body.slice("transaction_draft", "assistant_message").inspect
    assert_equal "Ross", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
  end

  test "explicit read only category followups never update a pending purchase" do
    before = @household.transaction_drafts.pending.sole.attributes
    post_message("Put it under Cigarettes but do not change anything")
    assert_nil response.parsed_body["transaction_draft"]
    assert_equal before, @household.transaction_drafts.pending.sole.attributes
  end

  test "this month ignores an old month open in the budget" do
    post "/api/v1/mia/messages", params: { message: "How am I doing this month?", year: 2025, month: 1 },
      headers: { "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test" }, as: :json
    assert_response :created
    assert_equal 2026, response.parsed_body.dig("month_answer", "year")
    assert_equal 7, response.parsed_body.dig("month_answer", "month")
    assert_includes reply, "July 2026"
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
