require "test_helper"
require_relative "../support/mel_persona_test_helper"

class ApiV1MiaMelCoachingTest < ActionDispatch::IntegrationTest
  include MelPersonaTestHelper
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

  test "reflections do not pile up record disclaimers and embarrassment gets support" do
    [ "I stayed under my grocery budget", "I went to Ross again", "I'm embarrassed I ordered takeout again" ].each do |message|
      post_message(message)
      refute_match(/not counted|checked spending|not a checked|have not counted/i, reply)
      refute response.parsed_body["transaction_draft"]
      refute response.parsed_body["mia_action_draft"]
    end
    assert_includes reply, "does not make you a failure"
    refute_match(/Umbee|Lanya|Chelu/i, reply)
  end

  test "month chat is three sentences with rounded figures while packet cents stay exact" do
    @household.household_transactions.find_by!(merchant: "Cafe").tap do |transaction|
      transaction.update!(total_amount_cents: 4555)
      transaction.transaction_splits.sole.update!(amount_cents: 4555)
    end
    post_message("How am I doing this month?")
    assert_match(/\AYour plan leaves/, reply)
    assert_includes reply, "$46"
    assert_equal 4555, response.parsed_body.dig("month_answer", "spent_so_far_cents")
    assert_equal 3, reply.split(/(?<=[.!?])\s+/).length
    refute_match(/Red|money in is|planned out is|\$45\.55/, reply)
  end

  test "inherited published Guam voice survives narration and persists its version" do
    membership, version = published_mel_program_for(@user)
    assert_nil membership.cohort.cohort_persona_assignment
    cohort = membership.cohort
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    cohort.update!(active_cohort_release: cohort.cohort_releases.sole)
    original = HouseholdFinance::MiaNarrator.method(:new)
    selected = nil
    packet = nil
    build = lambda do |**attributes|
      selected = attributes.fetch(:persona)
      packet = attributes.fetch(:answer_packet)
      original.call(**attributes.merge(api_key: "synthetic")).tap do |narrator|
        narrator.define_singleton_method(:openrouter_response) do
          "You noticed Ross is becoming a repeat stop. Chelu, pump the brakes on that one without beating yourself up. What was happening before you went in?"
        end
      end
    end
    begin
      HouseholdFinance::MiaNarrator.singleton_class.define_method(:new, build)
      post_message("I went to Ross again")
    ensure
      HouseholdFinance::MiaNarrator.singleton_class.define_method(:new, original)
    end
    assert_equal version.id, selected.version_id
    assert_nil packet[:annual_plan_summary]
    assert_includes reply, "Chelu, pump the brakes"
    assert_equal version.id, ChatMessage.where(role: "assistant").order(:id).last.coach_persona_version_id
  end

  test "purse affordability uses deterministic coaching before any intent model" do
    resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "I'm thinking of buying a $60 purse at Ross. Can I afford it?", context: {},
      api_key: "synthetic", transport: ->(*) { raise "intent model must not decide this familiar coaching question" })
    assert_equal "coaching", resolver.call.intent
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

  test "a month question does not swallow an incurred purchase in the same turn" do
    post_message("I spent $60 at Ross today. How am I doing this month?")
    draft = response.parsed_body.fetch("transaction_draft")
    assert draft, response.parsed_body.slice("assistant_message", "transaction_draft").inspect
    assert_equal "Ross", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
    assert_equal "pending", draft.fetch("status")
  end

  test "a supporting date sentence stays with a purchase beside a month question" do
    post_message("I spent $60 at Ross. It was yesterday. How am I doing this month?")
    draft = response.parsed_body.fetch("transaction_draft")
    assert draft, response.parsed_body.slice("assistant_message", "transaction_draft").inspect
    assert_equal "Ross", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
    assert_equal (Date.current - 1).iso8601, draft.fetch("occurred_on")
  end

  test "an incurred purchase following a month question still reaches review" do
    post_message("How am I doing this month? I spent $60 at Ross today.")
    draft = response.parsed_body.fetch("transaction_draft")
    assert draft, response.parsed_body.slice("assistant_message", "transaction_draft").inspect
    assert_equal "Ross", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
  end

  test "a date clarification with a tax component cannot replace the earlier total" do
    @household.transaction_drafts.destroy_all
    post_message("I spent $60 at Ross on February 30")
    assert_no_difference -> { @household.transaction_drafts.count } do
      post_message("It was yesterday, including $5 tax")
    end
    assert_nil response.parsed_body["transaction_draft"]
    assert_includes reply, "total Ross purchase amount"
  end

  test "the latest merchant in a purchase clarification overrides the earlier one" do
    @household.transaction_drafts.destroy_all
    post_message("I spent money at Ross today")
    post_message("It was $60 at Payless yesterday")
    draft = response.parsed_body.fetch("transaction_draft")
    assert draft, response.parsed_body.slice("assistant_message", "transaction_draft").inspect
    assert_equal "Payless", draft.fetch("merchant")
    assert_equal 6000, draft.fetch("amount_cents")
    assert_equal (Date.current - 1).iso8601, draft.fetch("occurred_on")
  end

  test "a total and component amount in a clarification ask rather than creating the component purchase" do
    @household.transaction_drafts.destroy_all
    post_message("I spent money at Ross today")
    assert_no_difference -> { @household.transaction_drafts.count } do
      post_message("It was $60, including $5 tax")
    end
    assert_nil response.parsed_body["transaction_draft"]
    assert_includes reply, "total Ross purchase amount"
  end

  test "month overview resolves an ISO year and month" do
    post_message("How am I doing in 2026-09?")
    assert_equal 2026, response.parsed_body.dig("month_answer", "year")
    assert_equal 9, response.parsed_body.dig("month_answer", "month")
    assert_includes reply, "September 2026"
  end

  test "an incomplete annual review list cannot establish no reviews in an older month" do
    @household.update!(created_at: Date.new(2026, 1, 1))
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).read_only_plan_data
    plan[:pending_transaction_drafts] = []
    plan[:pending_transaction_drafts_meta] = { total_count: 501, returned_count: 500, truncated: true }
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: 1)
    assert_nil answer.call[:pending_count]
    assert_nil answer.call[:pending_cents]
    assert answer.call[:pending_list_truncated]
    assert_includes answer.response, "review list is incomplete"
    refute_includes answer.response, "no purchases are waiting"
  end

  test "bare and spoken reported amounts still reach purchase review beside feelings or habits" do
    {
      "I went to Ross again and spent 60 today" => [ "Ross", 6000 ],
      "I spent 12 at Payless today. I feel stressed." => [ "Payless", 1200 ],
      "I went to Ross again and spent sixty dollars today" => [ "Ross", 6000 ]
    }.each do |message, (merchant, cents)|
      post_message(message)
      draft = response.parsed_body.fetch("transaction_draft")
      assert draft, response.parsed_body.slice("assistant_message", "transaction_draft").inspect
      assert_equal merchant, draft.fetch("merchant")
      assert_equal cents, draft.fetch("amount_cents")
      assert_equal "pending", draft.fetch("status")
    end
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
    assert_includes reply, "cushion"
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
    assert_includes item.description, "Beginning July:"
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
    post_message("Put it under a new Cigarettes category")
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
