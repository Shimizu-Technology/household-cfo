require "test_helper"
require_relative "../support/savings_challenge_test_support"
require_relative "../support/savings_debt_test_support"

class ApiV1SavingsMiaControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  include SavingsDebtTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll; savings_plan; savings_approve(savings_draft(20_001)) }
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "challenge coaching uses approved savings and bypasses annual setup and financial writes" do
    assert_no_difference [ "BudgetYear.count", "HouseholdTransaction.count", "SavingsEntryVersion.count", "TransactionDraft.count" ] do
      post "/api/v1/mia/messages", params: { message: "How much savings progress do I have?", request_id: "savings-progress" }, headers: auth, as: :json
      assert_response :created
    end
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes answer, "$200.01"
    assert_includes answer, "$500.00"
    assert_includes answer, "90-day"
    assert_includes answer, "So far you've saved"
    assert_nil response.parsed_body.fetch("budget")
    assert_nil response.parsed_body.fetch("transaction_draft")
    count = ChatMessage.count
    post "/api/v1/mia/messages", params: { message: "How much savings progress do I have?", request_id: "savings-progress" }, headers: auth, as: :json
    assert_response :created
    assert_equal count, ChatMessage.count
  end

  test "card, loan and hard-day questions get final answers without calling the model" do
    ENV["OPENROUTER_API_KEY"] = "fictional-key"
    with_savings_runtime { debt_approve(debt_stage(debt_terms(label: "Visa", balance_cents: 30_000))) }
    narrator_stub = stub_private_method(HouseholdFinance::MiaNarrator, :openrouter_response) { $model_calls_in_test = $model_calls_in_test.to_i + 1; nil }
    $model_calls_in_test = 0
    begin
      asks = [ "How much do I owe on my card according to what I approved?", "which card first and how much extra should I pay?",
        "Will this challenge help my loan application at the bank?", "i dont see the point anymore" ]
      answers = asks.each_with_index.map do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "final-#{index}" }, headers: auth, as: :json
        assert_response :created
        response.parsed_body.dig("assistant_message", "content")
      end
      assert_includes answers[0], "Visa, $300.00"
      assert_includes answers[0], "not a live balance"
      assert_includes answers[1], "cannot rank your cards or suggest an extra amount"
      assert_includes answers[2], "does not affect, and does not promise anything about, a loan decision"
      answers.each { |answer| refute_includes answer, "Start with one purchase" }
      hard = answers[3]
      assert_equal 1, hard.scan("988").length, hard
      assert_includes hard, "That sounds really heavy"
      assert_includes hard, "you can skip today"
      refute_includes hard, "stop the money coaching"
      assert_operator hard.index("you can skip today"), :<, hard.index("988")
      assert_equal 0, $model_calls_in_test
    ensure
      narrator_stub&.call
    end
  end

  test "crisis phrasing in the challenge keeps the deterministic crisis reply" do
    post "/api/v1/mia/messages", params: { message: "kms", request_id: "crisis-kms" }, headers: auth, as: :json
    assert_response :created
    assert_equal ::Mia::CrisisBoundary.response, response.parsed_body.dig("assistant_message", "content")
  end

  test "a closed or paused challenge still checks on hopeless language and keeps the crisis reply" do
    [ false, true ].each_with_index do |paused, index|
      @savings_cohort.update_columns(savings_challenge_release_hold: paused, status: paused ? "active" : "draft")
      post "/api/v1/mia/messages", params: { message: "i dont see the point anymore", request_id: "closed-hopeless-#{index}" }, headers: auth, as: :json
      assert_response :created
      content = response.parsed_body.dig("assistant_message", "content")
      if paused
        assert_includes content, "Your savings challenge is paused right now. Your record is safe and nothing is lost; you can continue when it resumes.", content
        assert_not_includes content, "isn't open yet"
      else
        assert_includes content, "isn't open yet", content
        assert_not_includes content, "paused"
      end
      assert_equal 1, content.scan("988").length, content
      post "/api/v1/mia/messages", params: { message: "i am not safe", request_id: "closed-crisis-#{index}" }, headers: auth, as: :json
      assert_equal ::Mia::CrisisBoundary.response, response.parsed_body.dig("assistant_message", "content")
    end
  end

  test "a bare plan statement after distress gets the crisis reply but a budget plan does not" do
    post "/api/v1/mia/messages", params: { message: "i cant do this anymore", request_id: "plan-1" }, headers: auth, as: :json
    post "/api/v1/mia/messages", params: { message: "i have a plan", request_id: "plan-2" }, headers: auth, as: :json
    assert_equal ::Mia::CrisisBoundary.response, response.parsed_body.dig("assistant_message", "content")
  end

  test "a bare plan statement without prior distress is not a crisis" do
    post "/api/v1/mia/messages", params: { message: "i have a plan", request_id: "plan-3" }, headers: auth, as: :json
    assert_response :created
    assert_not_equal ::Mia::CrisisBoundary.response, response.parsed_body.dig("assistant_message", "content")
  end

  test "a bare plan statement while the challenge is closed gets the safety line, and plain text does not" do
    @savings_cohort.update_columns(status: "draft")
    post "/api/v1/mia/messages", params: { message: "i have a plan", request_id: "closed-plan" }, headers: auth, as: :json
    content = response.parsed_body.dig("assistant_message", "content")
    assert_includes content, "isn't open yet"
    assert_equal 1, content.scan("988").length, content
    post "/api/v1/mia/messages", params: { message: "i have a plan for my budget", request_id: "closed-budget" }, headers: auth, as: :json
    assert_not_includes response.parsed_body.dig("assistant_message", "content"), "988"
  end

  test "hopeless language with food or essentials keeps food-first guidance and the 988 line without the model" do
    ENV["OPENROUTER_API_KEY"] = "fictional-key"
    narrator_stub = stub_private_method(HouseholdFinance::MiaNarrator, :openrouter_response) { $model_calls_in_test2 = $model_calls_in_test2.to_i + 1; nil }
    $model_calls_in_test2 = 0
    begin
      post "/api/v1/mia/messages", params: { message: "We have no food this week and I give up", request_id: "food-hopeless" }, headers: auth, as: :json
      assert_response :created
      content = response.parsed_body.dig("assistant_message", "content")
      assert_includes content, "Food comes first"
      assert_equal 1, content.scan("988").length, content
      post "/api/v1/mia/messages", params: { message: "i give up, i cannot afford rent", request_id: "rent-hopeless" }, headers: auth, as: :json
      content = response.parsed_body.dig("assistant_message", "content")
      assert_includes content, "Protect food, housing"
      assert_equal 1, content.scan("988").length, content
      assert_equal 0, $model_calls_in_test2
    ensure
      narrator_stub&.call
    end
  end

  test "debt free and optional feelings need no setup while hold blocks ordinary chat" do
    [ [ "I do not have credit cards", "without credit cards or debt" ], [ "I feel guilty", "leave feelings blank" ], [ "I bought lunch yesterday", "amount, where and date" ] ].each_with_index do |(message, expected), index|
      post "/api/v1/mia/messages", params: { message: message, request_id: "savings-topic-#{index}" }, headers: auth, as: :json
      assert_response :created
      assert_includes response.parsed_body.dig("assistant_message", "content"), expected
    end
    @savings_cohort.update!(savings_challenge_release_hold: true)
    assert_no_difference "ChatMessage.count" do
      post "/api/v1/mia/messages", params: { message: "How is my savings?", request_id: "held-chat" }, headers: auth, as: :json
      assert_response :created
      assert_includes response.parsed_body.dig("assistant_message", "content"), "paused right now"
    end
  end

  test "chat prepares exact review input while amounts ambiguous future or unreserved reductions never count" do
    assert_no_difference [ "SavingsEntryDraft.count", "SavingsEntryVersion.count", "SavingsDailyPurchaseDraft.count", "HouseholdTransaction.count" ] do
      post "/api/v1/mia/messages", params: { message: "I spent $12.35 at Synthetic Cafe today", request_id: "chat-purchase" }, headers: auth, as: :json
      assert_response :created
      intake = response.parsed_body.fetch("savings_intake")
      assert_equal "daily_report", intake.fetch("kind")
      assert_equal [ { "amount_cents" => 1235, "merchant" => "Synthetic Cafe", "purchased_on" => "2026-11-15" } ], intake.fetch("purchases")
      assert_equal "2026-11-15", intake.fetch("local_on")
      refute intake.fetch("counted")
      [ "Could I save $20 today?", "I saved $20 on 2026-11-16", "I spent $20 at Synthetic Cafe yesterday", "I have not yet saved $20 today", "I paid a credit card payment of $20 today" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "ambiguous-#{index}" }, headers: auth, as: :json
        assert_response :created
        assert_nil response.parsed_body.fetch("savings_intake")
      end
      post "/api/v1/mia/messages", params: { message: "I set aside $20.01 today", request_id: "chat-contribution" }, headers: auth, as: :json
      assert_response :created
      assert_equal 2001, response.parsed_body.dig("savings_intake", "signed_cents")
      assert response.parsed_body.dig("savings_intake", "new_money_confirmation_required")
    end
  end

  test "daily reports become one card the participant saves, with a reply that never claims a record" do
    ENV["OPENROUTER_API_KEY"] = "fictional-key"
    narrator_stub = stub_private_method(HouseholdFinance::MiaNarrator, :openrouter_response) { raise "daily reports must not call the narrator" }
    extractor_stub = stub_private_method(SavingsChallenge::DailyReportExtractor, :openrouter_response) { raise "a parsed daily report must not call the extractor" }
    assert_no_difference [ "SavingsDailyPurchaseDraft.count", "SavingsDailyPurchaseVersion.count", "SavingsDailyCheckInVersion.count", "SavingsDailyReflectionVersion.count", "HouseholdTransaction.count", "TransactionDraft.count" ] do
      post "/api/v1/mia/messages", params: { message: "I spent $8 at Shell and 20 at Payless, felt rushed", request_id: "daily-two" }, headers: auth, as: :json
      assert_response :created
      intake = response.parsed_body.fetch("savings_intake")
      assert_equal({ "kind" => "daily_report", "local_on" => "2026-11-15", "no_spend" => false, "counted" => false, "approval_state" => "unreviewed_input",
        "purchases" => [ { "amount_cents" => 800, "merchant" => "Shell", "purchased_on" => "2026-11-15" }, { "amount_cents" => 2000, "merchant" => "Payless", "purchased_on" => "2026-11-15" } ],
        "feelings" => { "when_spent" => "rushed", "now" => nil } }, intake)
      reply = response.parsed_body.dig("assistant_message", "content")
      assert_includes reply, "$8.00 at Shell and $20.00 at Payless"
      assert_includes reply, "tap Save. Nothing is saved until you do."
      refute_match(/\b(?:I|I've|we)\s+(?:saved|recorded|added)\b/i, reply.sub("Nothing is saved until you do.", ""))
      assert_nil response.parsed_body.fetch("transaction_draft")

      post "/api/v1/mia/messages", params: { message: "spent 12 for lunch", request_id: "daily-no-place" }, headers: auth, as: :json
      assert_equal "", response.parsed_body.dig("savings_intake", "purchases", 0, "merchant")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "Add where you spent it on the card"

      post "/api/v1/mia/messages", params: { message: "No spending today", request_id: "daily-no-spend" }, headers: auth, as: :json
      assert_response :created
      assert_equal({ "kind" => "daily_report", "local_on" => "2026-11-15", "purchases" => [], "no_spend" => true, "feelings" => nil,
        "counted" => false, "approval_state" => "unreviewed_input" }, response.parsed_body.fetch("savings_intake"))
      assert_includes response.parsed_body.dig("assistant_message", "content"), "No spending today. I've put it below"

      post "/api/v1/mia/messages", params: { message: "I spent nothing today but I feel stressed", request_id: "daily-no-spend-feeling" }, headers: auth, as: :json
      assert response.parsed_body.dig("savings_intake", "no_spend")
      assert_nil response.parsed_body.dig("savings_intake", "feelings")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "How you feel isn't saved with a no-spend day"

      # Day 1 of the personal window: yesterday cannot be recorded, and Mia says why.
      [ "spent $9 at Shell yesterday", "I didn't spend anything yesterday" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "daily-before-start-#{index}" }, headers: auth, as: :json
        assert_nil response.parsed_body.fetch("savings_intake"), message
        assert_equal "Your challenge started on Sun, Nov 15, so I can't add yesterday's spending to it. Nothing was saved. You can tell me about today instead.",
          response.parsed_body.dig("assistant_message", "content"), message
      end

      post "/api/v1/mia/messages", params: { message: "I feel stressed, spent $60 at Ross", request_id: "daily-feeling-first" }, headers: auth, as: :json
      assert_equal [ 6000 ], response.parsed_body.dig("savings_intake", "purchases").map { |row| row["amount_cents"] }
      assert response.parsed_body.dig("assistant_message", "content").start_with?("Thanks for telling me how you're feeling. Got it: $60.00 at Ross.")

      # Money talk that is not a purchase keeps Mia's normal answer and shows no card.
      [ "My goal is $500", "Rent went up to $1,400", "I have $180 left", "Mom gave me $50" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "daily-money-talk-#{index}" }, headers: auth, as: :json
        assert_nil response.parsed_body.fetch("savings_intake"), message
        refute_includes response.parsed_body.dig("assistant_message", "content"), "tap Save", message
      end

      [ "should I spend 20 at Ross?", "I might buy shoes at Ross", "paid 300 on my credit card", "bought 2 shares of Apple today" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "daily-negative-#{index}" }, headers: auth, as: :json
        assert_nil response.parsed_body.fetch("savings_intake"), message
      end
    end
  ensure
    narrator_stub&.call
    extractor_stub&.call
  end

  test "an unreadable daily report may use the stubbed extractor, which is validated and never counted" do
    ENV["OPENROUTER_API_KEY"] = "fictional-key"
    extractor_stub = stub_private_method(SavingsChallenge::DailyReportExtractor, :openrouter_response) { { purchases: [ { amount: "12", merchant: "Kings", day: "today" } ], no_spend: false, feeling_when_spent: "", feeling_now: "", counted: true }.to_json }
    post "/api/v1/mia/messages", params: { message: "lunch w my cousins came to 12 at Kings", request_id: "daily-extract-extra" }, headers: auth, as: :json
    assert_nil response.parsed_body.fetch("savings_intake"), "an extra field rejects the whole proposal"
    SavingsChallenge::DailyReportExtractor.class_eval do
      define_method(:openrouter_response) { { purchases: [ { amount: "12", merchant: "Kings", day: "today" } ], no_spend: false, feeling_when_spent: "", feeling_now: "" }.to_json }
    end
    narrator_stub = stub_private_method(HouseholdFinance::MiaNarrator, :openrouter_response) { raise "a daily report reply is deterministic" }
    assert_no_difference [ "SavingsDailyPurchaseDraft.count", "SavingsDailyPurchaseVersion.count" ] do
      post "/api/v1/mia/messages", params: { message: "lunch w my cousins came to 12 at Kings", request_id: "daily-extract" }, headers: auth, as: :json
    end
    assert_equal [ { "amount_cents" => 1200, "merchant" => "Kings", "purchased_on" => "2026-11-15" } ], response.parsed_body.dig("savings_intake", "purchases")
    refute response.parsed_body.dig("savings_intake", "counted")
  ensure
    extractor_stub&.call
    narrator_stub&.call
  end

  test "an ungrounded two-day model report falls back to Mia without a purchase card" do
    ENV["OPENROUTER_API_KEY"] = "fictional-key"
    extractor_stub = stub_private_method(SavingsChallenge::DailyReportExtractor, :openrouter_response) do
      { purchases: [ { amount: "12", merchant: "Kings", day: "today" }, { amount: "15", merchant: "Ross", day: "today" } ], no_spend: false, feeling_when_spent: "", feeling_now: "" }.to_json
    end
    narrator_stub = stub_private_method(HouseholdFinance::MiaNarrator, :openrouter_response) { "Tell me which purchase was yesterday and which was today." }
    assert_no_difference [ "SavingsDailyPurchaseDraft.count", "SavingsDailyPurchaseVersion.count" ] do
      post "/api/v1/mia/messages", params: { message: "lunch w cousins came to 12 at Kings yesterday and dinner w friends came to 15 at Ross today", request_id: "two-days-invalid" }, headers: auth, as: :json
      assert_response :created
      assert_nil response.parsed_body["savings_intake"]
      assert response.parsed_body.dig("assistant_message", "content").present?
    end
  ensure
    extractor_stub&.call
    narrator_stub&.call
  end

  test "crisis and wellbeing-check replies carry an explicit safety flag, in replies and in history" do
    [ [ "i dont see the point anymore", "hopeless" ], [ "kms", "crisis" ] ].each_with_index do |(message, kind), index|
      post "/api/v1/mia/messages", params: { message: message, request_id: "safety-#{index}" }, headers: auth, as: :json
      assert_response :created
      assert_equal true, response.parsed_body.dig("assistant_message", "safety_reply"), kind
      assert_includes response.parsed_body.dig("assistant_message", "content"), "988", kind
      assert_nil response.parsed_body["savings_intake"], kind
    end
    post "/api/v1/mia/messages", params: { message: "No spending today", request_id: "safety-after" }, headers: auth, as: :json
    assert_equal false, response.parsed_body.dig("assistant_message", "safety_reply")
    get "/api/v1/mia/messages", headers: auth
    assert_response :success
    flags = response.parsed_body.fetch("messages").select { |row| row["role"] == "assistant" }.map { |row| row["safety_reply"] }
    assert_equal [ true, true, false ], flags.last(3)
  end

  test "goal changes in the challenge point to the challenge target, and saved money gets a plain reply" do
    assert_no_difference [ "SavingsPlanDraft.count", "MiaActionDraft.count", "SavingsEntryDraft.count" ] do
      [ "Change my goal to $300", "Update my goal to $700" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "goal-#{index}" }, headers: auth, as: :json
        assert_response :created
        reply = response.parsed_body.dig("assistant_message", "content")
        assert_includes reply, "open Savings, then Your target & spending choices", message
        refute_includes reply, "household plan or your savings challenge", message
        assert_nil response.parsed_body["savings_intake"], message
      end
      post "/api/v1/mia/messages", params: { message: "Picked up an extra shift and saved $50 today", request_id: "plain-contribution" }, headers: auth, as: :json
      assert_equal "contribution", response.parsed_body.dig("savings_intake", "kind")
      assert_equal "Got it: $50.00 set aside today. I've put it below — check it, then save it to your challenge. Only new money you set aside counts, and nothing is saved until you do.",
        response.parsed_body.dig("assistant_message", "content")
    end
  end

  test "household category chat prepares an explicit review and applies once without changing savings" do
    assert_no_difference [ "SavingsEntryVersion.count", "SavingsPlanVersion.count", "SavingsDebtVersion.count", "HouseholdTransaction.count" ] do
      post "/api/v1/mia/messages", params: { message: "Create a new household discretionary category called Books with $25 for November 2026", year: 2026, month: 11, request_id: "household-category" }, headers: auth, as: :json
      assert_response :created
      card = response.parsed_body.fetch("mia_action_draft")
      assert card, response.parsed_body.inspect
      assert_equal "household_plan", card.fetch("record_scope")
      assert_includes card.fetch("scope_note"), "do not approve challenge savings"
      assert_nil @savings_household.budget_categories.find_by(name: "Books")
      assert_nil response.parsed_body.fetch("transaction_draft")
      assert_equal @savings_cohort.id, MiaActionDraft.find(card.fetch("id")).source_chat_message.chat_session.cohort_id

      headers = auth.merge("Idempotency-Key" => "apply-household-category")
      post "/api/v1/mia_action_drafts/#{card.fetch('id')}/apply", headers: headers, as: :json
      assert_response :success
      category = @savings_household.budget_categories.find_by!(name: "Books")
      assert_equal 2500, category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(2026, 11, 1) }).planned_amount_cents
      assert_no_difference [ "BudgetCategory.count", "HouseholdOperationExecution.count" ] do
        post "/api/v1/mia_action_drafts/#{card.fetch('id')}/apply", headers: headers, as: :json
        assert_response :success
      end
    end
  end

  test "ambiguous goal and debt edits ask which records without creating annual setup" do
    [ "Change my card balance to $900", "Update household debt and my challenge target" ].each_with_index do |message, index|
      assert_no_difference [ "BudgetYear.count", "MiaActionDraft.count", "SavingsPlanDraft.count", "SavingsDebtDraft.count" ] do
        post "/api/v1/mia/messages", params: { message: message, request_id: "scope-#{index}" }, headers: auth, as: :json
        assert_response :created
        assert_includes response.parsed_body.dig("assistant_message", "content"), "household plan or your savings challenge"
        assert_nil response.parsed_body.fetch("mia_action_draft")
      end
    end
  end

  test "household review cards cannot apply or cancel in another program or after a hold" do
    post "/api/v1/mia/messages", params: { message: "Create a new discretionary category called Reading with $30 for November 2026", year: 2026, month: 11, request_id: "scope-card" }, headers: auth, as: :json
    assert_response :created
    id = response.parsed_body.dig("mia_action_draft", "id")
    delete "/api/v1/mia/messages", headers: auth, as: :json
    assert_response :success
    assert_nil MiaActionDraft.find(id).source_chat_message_id
    ordinary = Cohort.create!(name: "Ordinary coaching", status: "active", created_by_user: @savings_owner)
    ordinary.cohort_memberships.create!(user: @savings_user, role: "participant")
    ordinary_headers = auth.merge("X-Cohort-Id" => ordinary.id.to_s, "Idempotency-Key" => "wrong-program")
    %w[apply cancel].each do |operation|
      assert_no_difference "MiaActionDraftApplication.count" do
        post "/api/v1/mia_action_drafts/#{id}/#{operation}", headers: ordinary_headers, as: :json
        assert_response :conflict
      end
    end
    @savings_cohort.update!(savings_challenge_release_hold: true)
    assert_no_difference [ "BudgetCategory.count", "MiaActionDraftApplication.count" ] do
      post "/api/v1/mia_action_drafts/#{id}/apply", headers: auth.merge("Idempotency-Key" => "held-card"), as: :json
      assert_response :forbidden
    end
    assert_equal "pending", MiaActionDraft.find(id).status
  end

  test "model cannot route a household request to a transaction write" do
    result = HouseholdFinance::MiaIntentResolver::Result.new(intent: "transaction_report", confidence: 1.0,
      action: { type: "create_transaction_draft", merchant: "Other", amount: "25", occurred_on: "2026-11-15" },
      read_only_plan: {}, resolved_message: "I spent $25 at Other today")
    resolver = Object.new
    resolver.define_singleton_method(:call) { result }
    with_intent_resolver(resolver) do
      assert_no_difference [ "BudgetYear.count", "TransactionDraft.count", "HouseholdTransaction.count", "MiaActionDraft.count" ] do
        post "/api/v1/mia/messages", params: { message: "Update my household income to $2500 monthly", request_id: "misclassified-household" }, headers: auth, as: :json
        assert_response :created
        assert_nil response.parsed_body.fetch("transaction_draft")
        assert_includes response.parsed_body.dig("assistant_message", "content"), "household plan or your savings challenge"
      end
    end
  end

  test "BOG saved income lookup is grounded without provider or financial writes" do
    @savings_household.income_sources.create!(label: "Primary salary", source_type: "job", amount_cents: 400_000, cadence: "monthly")
    @savings_household.income_sources.create!(label: "Tutoring", source_type: "business", amount_cents: 30_000, cadence: "monthly")
    assert_no_difference [ "BudgetYear.count", "MiaActionDraft.count", "SavingsEntryVersion.count" ] do
      post "/api/v1/mia/messages", params: { message: "List all my saved income sources and their amounts", year: 2026, month: 11, request_id: "saved-income" }, headers: auth, as: :json
      assert_response :created
      answer = response.parsed_body.dig("assistant_message", "content")
      assert_includes answer, "Primary salary"
      assert_includes answer, "Tutoring"
      assert_includes answer, "$4,300.00"
      assert_nil response.parsed_body.fetch("budget")
      assert_nil response.parsed_body.fetch("mia_action_draft")
    end
  end

  test "BOG uses the shared reviewed income debt account and tracked goal operations" do
    requests = [
      [ "income_action", "Create a household income source Freelance for $500 monthly starting November 2026", { type: "create_income_source", income_source_name: "Freelance", source_type: "business", amount: "500", cadence: "monthly", effective_on: "2026-11-01" }, IncomeSource, "Freelance" ],
      [ "debt_action", "Create a household credit card debt named Test Visa with unknown balance and minimum", { type: "create_debt", debt_name: "Test Visa", debt_type: "credit_card", amount: "unknown", minimum_payment: "unknown" }, Debt, "Test Visa" ],
      [ "asset_action", "Create a household checking account named Test checking with a $0 balance", { type: "create_account", account_name: "Test checking", account_type: "checking", amount: "0" }, Account, "Test checking" ],
      [ "goal_action", "Create a household tracked travel goal named Trip with target $1000 and unknown progress", { type: "create_goal", goal_name: "Trip", goal_type: "travel", target_amount: "1000", current_amount: "unknown" }, Goal, "Trip" ]
    ]
    requests.each_with_index do |(intent, message, action, model, label), index|
      result = HouseholdFinance::MiaIntentResolver::Result.new(intent: intent, confidence: 1.0, resolved_message: message,
        action: action, read_only_plan: {}, topic: {}, source: "model")
      resolver = Object.new
      resolver.define_singleton_method(:call) { result }
      with_intent_resolver(resolver) do
        assert_no_difference [ "#{model.name}.count", "SavingsEntryVersion.count", "SavingsDebtVersion.count", "SavingsPlanVersion.count", "HouseholdTransaction.count" ] do
          post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 11, request_id: "household-family-#{index}" }, headers: auth, as: :json
          assert_response :created
        end
      end
      card = response.parsed_body.fetch("mia_action_draft")
      assert card, response.parsed_body.inspect
      assert_equal "household_plan", card.fetch("record_scope")
      assert_difference "#{model.name}.count", 1 do
        assert_no_difference [ "SavingsEntryVersion.count", "SavingsDebtVersion.count", "SavingsPlanVersion.count", "HouseholdTransaction.count" ] do
          post "/api/v1/mia_action_drafts/#{card.fetch('id')}/apply", headers: auth.merge("Idempotency-Key" => "apply-family-#{index}"), as: :json
          assert_response :success
        end
      end
      record = model.find_by!(household: @savings_household, label: label)
      refute record.balance_known? if model == Debt
      refute record.current_amount_known? if model == Goal
      assert_equal 0, record.balance_cents if model == Account
    end
  end

  test "a natural income update in BOG prepares household review without changing challenge records" do
    assert_no_difference [ "IncomeSource.count", "SavingsEntryVersion.count", "SavingsPlanVersion.count" ] do
      post "/api/v1/mia/messages", params: { message: "My take-home pay is now $6,200 a month", request_id: "natural-income" }, headers: auth, as: :json
      assert_response :created
      card = response.parsed_body.fetch("mia_action_draft")
      assert card, response.parsed_body.inspect
      assert_equal "household_plan", card.fetch("record_scope")
      assert_includes card.fetch("items").to_json, "620000"
    end
  end

  test "named household records route to reviewed edits without requiring a financial keyword" do
    category = @savings_household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary")
    assert_equal :household, Mia::HouseholdPlanRequest.classify("Set Dining Out to $200 next month", household: @savings_household)
    assert_equal :household, Mia::HouseholdPlanRequest.classify("Rename Dining Out to Restaurants", household: @savings_household)
    @savings_household.income_sources.create!(label: "Primary salary", source_type: "job", cadence: "monthly", amount_cents: 400_000)
    assert_equal :household, Mia::HouseholdPlanRequest.classify("Archive Primary salary", household: @savings_household)
    HouseholdFinance::AnnualBudgetManager.new(@savings_household, year: 2026).ensure_plan!
    assert_no_difference [ "BudgetAllocation.count", "SavingsEntryVersion.count", "HouseholdTransaction.count" ] do
      post "/api/v1/mia/messages", params: { message: "Set Dining Out to $200 next month", year: 2026, month: 11, request_id: "named-category" }, headers: auth, as: :json
      assert_response :created
      assert_equal category.id, response.parsed_body.dig("mia_action_draft", "items", 0, "target_record_id")
    end
  end

  test "scoping before review limits preserves each program queue and its count" do
    ordinary = Cohort.create!(name: "Ordinary queue", status: "active", created_by_user: @savings_owner)
    membership = ordinary.cohort_memberships.create!(user: @savings_user, role: "participant")
    old = @savings_household.mia_action_drafts.create!(requested_by_user: @savings_user, draft_type: "budget_edit", year: 2026,
      title: "Ordinary review", summary: "Ordinary plan review", metadata: { review_program_scope: { cohort_id: nil, user_id: @savings_user.id } })
    11.times do |index|
      @savings_household.mia_action_drafts.create!(requested_by_user: @savings_user, draft_type: "budget_edit", year: 2026,
        title: "Challenge household review #{index}", summary: "Challenge household plan review",
        metadata: { review_program_scope: { cohort_id: @savings_cohort.id, user_id: @savings_user.id } })
    end
    ordinary_presenter = HouseholdFinance::DataPresenter.new(@savings_household, user: @savings_user, cohort_membership: membership)
    assert_equal [ old.id ], ordinary_presenter.budget.fetch(:annual_plan).fetch(:pending_mia_action_drafts).map { |draft| draft[:id] }
    assert_equal 1, ordinary_presenter.dashboard.fetch(:action_center).fetch(:mia_action_review_count)
    challenge_presenter = HouseholdFinance::DataPresenter.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
    assert_equal 10, challenge_presenter.budget.fetch(:annual_plan).fetch(:pending_mia_action_drafts).length
    assert_equal 11, challenge_presenter.dashboard.fetch(:action_center).fetch(:mia_action_review_count)
    refute_includes challenge_presenter.budget.fetch(:annual_plan).fetch(:pending_mia_action_drafts).map { |draft| draft[:id] }, old.id
  end

  test "unsupported read periods clarify without creating a monthly plan in either program" do
    ordinary = Cohort.create!(name: "Ordinary reads", status: "active", created_by_user: @savings_owner)
    ordinary.cohort_memberships.create!(user: @savings_user, role: "participant")
    [ @savings_cohort.id, ordinary.id ].each do |cohort_id|
      assert_no_difference [ "BudgetYear.count", "BudgetAllocation.count", "MiaActionDraft.count" ] do
        post "/api/v1/mia/messages", params: { message: "Show my income for 2026-13", request_id: "invalid-read-#{cohort_id}" }, headers: auth.merge("X-Cohort-Id" => cohort_id.to_s), as: :json
        assert_response :created
        assert_includes response.parsed_body.dig("assistant_message", "content"), "one valid month"
        assert_nil response.parsed_body.fetch("budget")
      end
    end
  end

  test "explicit household budget analysis stays read only and a model cannot turn it into an edit" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@savings_household, year: 2026)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 200)
    manager.create_category!(name: "Housing", stack_key: "non_discretionary", monthly_amount: 300)
    dining.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(2026, 7, 1) }).update!(planned_amount_cents: 50_000)
    assert_no_difference [ "BudgetYear.count", "BudgetAllocation.count", "MiaActionDraft.count", "HouseholdTransaction.count", "SavingsEntryVersion.count" ] do
      post "/api/v1/mia/messages", params: { message: "What is my largest household budget category?", year: 2026, month: 7, request_id: "household-analysis" }, headers: auth, as: :json
      assert_response :created
      assert_includes response.parsed_body.dig("assistant_message", "content"), "Dining Out"
      assert_includes response.parsed_body.dig("assistant_message", "content"), "$500 planned"
      assert_nil response.parsed_body.fetch("budget")
      assert_nil response.parsed_body.fetch("mia_action_draft")
    end
    category = @savings_household.budget_categories.find_by!(name: "Dining Out")
    result = HouseholdFinance::MiaIntentResolver::Result.new(intent: "budget_action", confidence: 1.0,
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "500", months: [ 11 ], year: 2026 },
      read_only_plan: {}, resolved_message: "Set Dining Out to $500")
    resolver = Object.new
    resolver.define_singleton_method(:call) { result }
    with_intent_resolver(resolver) do
      assert_no_difference [ "MiaActionDraft.count", "BudgetAllocation.count" ] do
        post "/api/v1/mia/messages", params: { message: "What is my largest household budget category?", request_id: "read-misclassified" }, headers: auth, as: :json
        assert_response :created
        assert_nil response.parsed_body.fetch("mia_action_draft")
      end
    end
  end

  test "household pronoun corrections continue the selected thread and challenge reports retire it" do
    @savings_household.goals.create!(label: "Today", goal_type: "savings", record_kind: "tracked", target_amount_cents: 100_000)
    post "/api/v1/mia/messages", params: { message: "Create a discretionary category called Books with $25 for November 2026", year: 2026, month: 11, request_id: "thread-create" }, headers: auth, as: :json
    assert_response :created
    assert response.parsed_body.fetch("mia_action_draft")
    session = @savings_household.chat_sessions.find_by!(user: @savings_user, cohort: @savings_cohort)
    assert_equal "household_plan", session.reload.active_topic["record_scope"]
    post "/api/v1/mia/messages", params: { message: "Change it to $30", year: 2026, month: 11, request_id: "thread-correct" }, headers: auth, as: :json
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Household plan:"
    assert_nil response.parsed_body.fetch("transaction_draft")
    post "/api/v1/mia/messages", params: { message: "I set aside $20 today", request_id: "thread-challenge" }, headers: auth, as: :json
    assert_response :created
    assert_equal "contribution", response.parsed_body.dig("savings_intake", "kind")
    assert_nil response.parsed_body.fetch("mia_action_draft")
    assert_empty session.reload.active_topic
    [ "Yes, I set aside $20 today", "Yep, I set aside $20 today", "Okay. I set aside $20 today", "We just set aside $20 today" ].each_with_index do |message, index|
      session.update!(active_topic: { "schema_version" => 2, "record_scope" => "household_plan" })
      post "/api/v1/mia/messages", params: { message: message, request_id: "ack-challenge-#{index}" }, headers: auth, as: :json
      assert_response :created
      assert_equal "contribution", response.parsed_body.dig("savings_intake", "kind")
      assert_nil response.parsed_body.fetch("mia_action_draft")
      refute_includes response.parsed_body.dig("assistant_message", "content"), "Household plan:"
      assert_empty session.reload.active_topic
    end
    session.update!(active_topic: { "schema_version" => 2, "record_scope" => "household_plan" })
    post "/api/v1/mia/messages", params: { message: "Change it to $600 for my savings goal", request_id: "explicit-challenge" }, headers: auth, as: :json
    assert_response :created
    assert_nil response.parsed_body.fetch("mia_action_draft")
    refute_includes response.parsed_body.dig("assistant_message", "content"), "Household plan:"
    assert_empty session.reload.active_topic
  end

  private
  # Replaces a private instance method for one test and returns a restorer that
  # puts the original back, still private. `method_defined?` ignores private
  # methods, so restoring by alias name alone can silently leave a stub behind
  # for every later test in the process.
  def stub_private_method(klass, name, &body)
    original = klass.instance_method(name)
    klass.send(:define_method, name, &body)
    klass.send(:private, name)
    -> { klass.send(:define_method, name, original); klass.send(:private, name) }
  end

  def with_intent_resolver(resolver)
    singleton = class << HouseholdFinance::MiaIntentResolver; self; end
    defined_before = singleton.method_defined?(:new, false)
    original_new = singleton.instance_method(:new) if defined_before
    singleton.define_method(:new) { |**_kwargs| resolver }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new, false)
    singleton.define_method(:new, original_new) if defined_before
  end

  def auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
end
