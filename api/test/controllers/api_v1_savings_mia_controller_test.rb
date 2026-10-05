require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1SavingsMiaControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
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
    assert_includes answer, "approved reported"
    assert_nil response.parsed_body.fetch("budget")
    assert_nil response.parsed_body.fetch("transaction_draft")
    count = ChatMessage.count
    post "/api/v1/mia/messages", params: { message: "How much savings progress do I have?", request_id: "savings-progress" }, headers: auth, as: :json
    assert_response :created
    assert_equal count, ChatMessage.count
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
      assert_response :forbidden
    end
  end

  test "chat prepares exact review input while amounts ambiguous future or unreserved reductions never count" do
    assert_no_difference [ "SavingsEntryDraft.count", "SavingsEntryVersion.count", "SavingsDailyPurchaseDraft.count", "HouseholdTransaction.count" ] do
      post "/api/v1/mia/messages", params: { message: "I spent $12.35 at Synthetic Cafe today", request_id: "chat-purchase" }, headers: auth, as: :json
      assert_response :created
      intake = response.parsed_body.fetch("savings_intake")
      assert_equal "purchase", intake.fetch("kind")
      assert_equal 1235, intake.fetch("amount_cents")
      assert_equal "2026-11-15", intake.fetch("effective_on")
      assert_equal "Synthetic Cafe", intake.fetch("merchant")
      refute intake.fetch("counted")
      [ "Could I save $20 today?", "I spent $20 and $30 today", "I saved $20 on 2026-11-16", "I spent $20 at Synthetic Cafe yesterday", "I have not yet saved $20 today", "I paid a credit card payment of $20 today" ].each_with_index do |message, index|
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
    [ "Update my goal to $700", "Change my card balance to $900", "Update household debt and my challenge target" ].each_with_index do |message, index|
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

  private
  def with_intent_resolver(resolver)
    singleton = class << HouseholdFinance::MiaIntentResolver; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |**_kwargs| resolver }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end

  def auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
end
