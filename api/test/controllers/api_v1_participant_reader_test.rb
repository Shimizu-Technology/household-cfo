require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1ParticipantReaderTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    with_savings_runtime { savings_enroll }
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    @user = User.create!(clerk_id: "reader_#{SecureRandom.hex(8)}", email: "reader-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  def reading(care: "none", facts: [], field: "none", value: "", correction: false, preferences: [])
    { care: care, facts: facts, question: false, setup_answer: { field: field, value: value }, correction: correction, spending_preferences: preferences }
  end

  def fact(kind, amount, day: "today", merchant: "", item: "")
    { kind: kind, amount: amount, merchant: merchant, item: item, day: day }
  end

  def with_reading(data)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) do |**options|
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    yield
  ensure
    klass.define_singleton_method(:call, original)
  end

  def household_say(message, data)
    with_reading(data) do
      post "/api/v1/mia/messages", params: { message: message }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
      assert_response :created
    end
    response.parsed_body
  end

  def begin_setup(**values)
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid,
      attributes: { household_name: "Reader household", primary_goal: "A house" }.merge(values)).call
    household_say("Help me set up my household", reading)
  end

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }, as: :json
    assert_response :success
  end

  test "reader preserves care and independent mixed cards through replay without saving" do
    text = "they cut my hours but i saved 20 today and 10 yesterday, bought lunch 12 today"
    data = reading(care: "hardship", facts: [ fact("set_aside", "20"), fact("set_aside", "10", day: "yesterday"), fact("purchase", "12", item: "lunch") ])
    with_reading(data) do
      with_savings_runtime do
        assert_no_difference [ "SavingsEntryVersion.count", "HouseholdTransaction.count" ] do
          post "/api/v1/mia/messages", params: { message: text, client_request_id: "reader-mixed" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
          assert_response :created
        end
        json = response.parsed_body
        assert_match(/sounds hard/i, json.dig("assistant_message", "content"))
        cards = json.fetch("challenge_chat_cards")
        assert_equal 3, cards.length
        assert_equal [ 2000, 1000 ], cards.first(2).map { |card| card.dig("input", "amount_cents") }
        assert_equal 1200, cards.last.dig("input", "purchases", 0, "amount_cents")
        assert_equal [ @savings_enrollment.local_today.iso8601, (@savings_enrollment.local_today - 1).iso8601 ], cards.first(2).map { |card| card.dig("input", "effective_on") }
        post "/api/v1/mia/messages", params: { message: text, client_request_id: "reader-mixed" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_equal cards.map { |card| card["id"] }, response.parsed_body.fetch("challenge_chat_cards").map { |card| card["id"] }
      end
    end
  end

  test "care comes before an ambiguous repeated movement while one card remains pending" do
    text = "they cut my hours but i moved $15 to savings and saved $15 today"
    with_reading(reading(care: "hardship", facts: [ fact("set_aside", "$15"), fact("set_aside", "$15") ])) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: text }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_match(/sounds hard/i, json.dig("assistant_message", "content"))
        assert_equal 1, json.fetch("challenge_chat_cards").length
        assert_equal 1500, json.dig("challenge_chat_card", "input", "amount_cents")
        assert_equal 0, SavingsEntryVersion.count
      end
    end
  end

  test "repeated equal movement facts ask once and never offer a double count" do
    with_reading(reading(facts: [ fact("set_aside", "$15"), fact("set_aside", "$15") ])) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "moved $15 to savings and saved $15 today" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_equal 1, json.fetch("challenge_chat_cards").length
        assert_includes json.dig("assistant_message", "content"), "one savings movement or two"
        assert_equal 0, SavingsEntryVersion.count
      end
    end
  end

  test "reader quotes determine savings bank movement withdrawal and deposit purchase cards" do
    [ [ "saved $20 at the credit union today", "set_aside", "$20", "contribution", 2000 ],
      [ "moved $50 from savings to checking today", "withdrawal", "$50", "withdrawal", -5000 ],
      [ "reserved a table $50 deposit today", "purchase", "$50", nil, nil ] ].each_with_index do |(text, kind, amount, movement, signed), index|
      with_reading(reading(facts: [ fact(kind, amount, item: kind == "purchase" ? "deposit" : "") ])) do
        with_savings_runtime do
          post "/api/v1/mia/messages", params: { message: text, client_request_id: "reader-sign-#{index}" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
          assert_response :created
          input = response.parsed_body.fetch("challenge_chat_card").fetch("input")
          assert_equal movement || "daily_report", input["kind"]
          assert_equal signed, input["signed_cents"] if movement
        end
      end
    end
    assert_equal 0, SavingsEntryVersion.count
  end

  test "new corrections replace only the pending setup field" do
    begin_setup
    first = household_say("4800", reading(field: "income", value: "4800"))
    old = first.fetch("mia_action_draft").fetch("id")
    %w[oops wait].each do |prefix|
      json = household_say("#{prefix} 4500", reading(field: "income", value: "4500", correction: true))
      assert json["mia_action_draft"], json.inspect
      assert_equal "canceled", MiaActionDraft.find(old).status
      assert_empty @household.income_sources
      old = json.fetch("mia_action_draft").fetch("id")
    end
    apply(response.parsed_body.fetch("mia_action_draft"))
    assert_equal 450000, @household.income_sources.sole.amount_cents
  end

  test "reader accepts fixed total including groceries and only applied preferences affect statement defaults" do
    begin_setup(primary_income: 4800)
    json = household_say("$2000 including groceries", reading(field: "fixed", value: "$2000", preferences: [ { family: "groceries", group: "fixed", evidence: "including groceries" } ]))
    draft = json.fetch("mia_action_draft")
    assert draft, json.inspect
    assert_equal "fixed", MiaActionDraft.find(draft.fetch("id")).metadata.dig("spending_preferences", 0, "group")
    apply(draft)
    household_say("700", reading(field: "flexible", value: "700"))
    apply(response.parsed_body.fetch("mia_action_draft"))
    policy = HouseholdFinance::EverydaySpendingPolicy.new(@household)
    assert_equal "non_discretionary", policy.suggestion(merchant: "Payless")[:category].stack_key
    assert_equal 200000, @household.budget_categories.find_by!(stack_key: "non_discretionary").budget_allocations.maximum(:planned_amount_cents)
  end

  test "a standalone split preference survives the next fixed answer and review" do
    begin_setup(primary_income: 4800)
    json = household_say("groceries go in bills", reading(preferences: [ { family: "groceries", group: "fixed", evidence: "groceries go in bills" } ]))
    assert_nil json["mia_action_draft"]
    assert_includes json.dig("assistant_message", "content"), "fixed essentials"
    json = household_say("2000", reading(field: "fixed", value: "2000"))
    assert_equal "fixed", MiaActionDraft.find(json.dig("mia_action_draft", "id")).metadata.dig("spending_preferences", 0, "group")
  end

  test "compound fixed costs and named debts ask for one total without purchases" do
    begin_setup(primary_income: 4800)
    json = household_say("rent 1200 and power 300", reading(facts: [ fact("bill", "1200", item: "rent", day: ""), fact("bill", "300", item: "power", day: "") ], field: "fixed", value: "1200 and power 300"))
    assert_nil json["mia_action_draft"]
    assert_nil json["transaction_draft"]
    assert_match(/one.*total/i, json.dig("assistant_message", "content"))
    refute_match(/couldn.t read/i, json.dig("assistant_message", "content"))
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid, attributes: { fixed_expenses: 2000, flexible_spend: 650 }).call
    household_say("Help me set up my household", reading)
    json = household_say("visa 40 and jcpenney 25", reading(facts: [ fact("purchase", "40", merchant: "visa", day: ""), fact("purchase", "25", merchant: "jcpenney", day: "") ]))
    assert_nil json["transaction_draft"]
    assert_nil json["mia_action_draft"]
    assert_match(/one.*total/i, json.dig("assistant_message", "content"))
  end

  test "an unavailable setup reader does not press the next question or name an absent Savings screen" do
    household_say("Help me set up my household", reading)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) { |**options| new(**options.merge(transport: ->(_) { raise Net::ReadTimeout })).call }
    post "/api/v1/mia/messages", params: { message: "they laid me off and im scared" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_match(/try again/i, reply)
    refute_match(/Next setup question|Savings screen|call this household/i, reply)
    assert_nil response.parsed_body["mia_action_draft"]
  ensure
    klass&.define_singleton_method(:call, original) if original
  end

  test "an explicit draft request can prepare an undrafted recalled action but never replay an applied review" do
    begin_setup(primary_income: 4800, fixed_expenses: 2000, flexible_spend: 650)
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    category = manager.create_category!(name: "School supplies", stack_key: "discretionary", monthly_amount: 100)
    session = @household.chat_sessions.find_by!(user: @user)
    session.update!(active_topic: { schema_version: 2, id: SecureRandom.uuid, type: "budget_edit", title: "School supplies", status: "needs_clarification", year: 2026,
      action: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "300", months: [ 11 ], year: 2026 } })
    klass = HouseholdFinance::MiaIntentResolver
    original = klass.instance_method(:call)
    klass.define_method(:call) { nil }
    json = household_say("draft that", reading)
    assert json["mia_action_draft"], json.inspect
    apply(json["mia_action_draft"])
    count = MiaActionDraft.count
    household_say("draft that", reading)
    assert_equal count, MiaActionDraft.count
  ensure
    klass&.define_method(:call, original) if original
  end

  test "a mixed undated savings report asks its day without hiding the purchase or amount" do
    with_reading(reading(facts: [ fact("purchase", "9", item: "lunch", day: ""), fact("set_aside", "5", day: "") ])) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "lunch 9 and saved 5" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
      end
    end
    assert_response :created
    assert_equal 1, response.parsed_body.fetch("challenge_chat_cards").length
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_match(/9/, reply)
    assert_match(/5.*which day|which day.*5/i, reply)
  end

  test "an exact grief disclosure still leads with care when the reader is off" do
    begin_setup
    post "/api/v1/mia/messages", params: { message: "My mom passed" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    assert_nil response.parsed_body["mia_action_draft"]
    assert_match(/sorry for your loss/i, response.parsed_body.dig("assistant_message", "content"))
    assert_empty @household.income_sources
  end

  test "an old financial picture question cannot open a setup field for the reader" do
    session = @household.chat_sessions.create!(user: @user)
    session.chat_messages.create!(role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("household_name"))
    @household.update_column(:financial_generation, 1)
    fields = []
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    data = reading
    klass.define_singleton_method(:call) do |**options|
      fields << options[:setup_field]
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    post "/api/v1/mia/messages", params: { message: "not sure yet" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}", "X-Financial-Generation" => "1" }, as: :json
    assert_response :created
    assert_equal [ nil ], fields
    assert_nil response.parsed_body["mia_action_draft"]
  ensure
    klass&.define_singleton_method(:call, original) if original
  end

  test "a reader purchase preserves its stated past date and rejects future or invalid dates" do
    begin_setup
    text = "I spent 12 at Shell on 2026-11-25"
    json = household_say(text, reading(facts: [ fact("purchase", "12", merchant: "Shell", day: "2026-11-25") ]))
    assert_equal "2026-11-25", json.fetch("transaction_draft").fetch("occurred_on")

    %w[2026-12-02 2026-02-30].each do |day|
      json = household_say("I spent 12 at Shell on #{day}", reading(facts: [ fact("purchase", "12", merchant: "Shell", day: day) ]))
      assert_nil json["transaction_draft"]
      assert_nil json["mia_action_draft"]
      assert_match(/purchase date.*today or earlier/i, json.dig("assistant_message", "content"))
    end
    assert_empty @household.household_transactions
  end

  test "junk setup and outages repeat the question without a name or goal card" do
    household_say("Help me set up my household", reading)
    %w[idk none hi rent groceries ya k].each do |message|
      json = household_say(message, reading)
      assert_nil json["mia_action_draft"], message
      assert_includes json.dig("assistant_message", "content"), "What would you like to call"
    end
    post "/api/v1/mia/messages", params: { message: "sounds good" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    assert_nil response.parsed_body["mia_action_draft"]
    assert_includes response.parsed_body.dig("assistant_message", "content"), "couldn't read"
    with_savings_runtime do
      post "/api/v1/mia/messages", params: { message: "cant believe i saved $40 today" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
      assert_response :created
      assert_empty response.parsed_body["challenge_chat_cards"]
      assert_includes response.parsed_body.dig("assistant_message", "content"), "try again"
    end
  end
end
