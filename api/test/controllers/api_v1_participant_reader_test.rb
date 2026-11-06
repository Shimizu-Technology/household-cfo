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

  test "pending bill additions and named corrections preserve prior parts through Apply" do
    begin_setup(primary_income: 3500)
    entries = [
      [ "rent 1080 and power 220", false, [ { source: "rent 1080", amount: "1080" }, { source: "power 220", amount: "220" } ], "Rent $1,080 + power $220 = $1,300" ],
      [ "oh and water is 60", false, [ { source: "water is 60", amount: "60" } ], "Rent $1,080 + power $220 + water $60 = $1,360" ],
      [ "wait power is 250", true, [ { source: "power is 250", amount: "250" } ], "Rent $1,080 + power $250 + water $60 = $1,390" ]
    ]
    cards = entries.map do |message, correction, parts, expected|
      json = household_say(message, reading(correction: correction).merge(setup_details: { field: "fixed_expenses", cadence: "monthly", count: "", partial: true, components: parts }))
      assert_includes json.dig("assistant_message", "content"), expected
      card = json.fetch("mia_action_draft")
      assert card, json.inspect
      assert_equal parts.length == 2 ? 2 : 3, MiaActionDraft.find(card["id"]).metadata.dig("setup_calculation", "components").length
      card
    end
    refute_includes @household.reload.confirmed_setup_fields, "fixed_expenses"
    apply(cards.last)
    assert_includes @household.reload.confirmed_setup_fields, "fixed_expenses"
    assert_equal 139000, @household.budget_categories.find_by!(stack_key: "non_discretionary").budget_allocations.maximum(:planned_amount_cents)
    cards.first(2).each { |card| assert_equal "canceled", MiaActionDraft.find(card["id"]).status }
  end

  test "asking the same setup definition twice uses another return question" do
    begin_setup(primary_income: 3500)
    first = household_say("what are fixed essentials", reading.merge(question: true)).dig("assistant_message", "content")
    second = household_say("what are fixed essentials", reading.merge(question: true)).dig("assistant_message", "content")
    refute_equal first, second
    assert_includes second, HouseholdFinance::MiaSetupGuide::RETRY_QUESTIONS.fetch("fixed_expenses")
  end

  test "skipping every remaining question pauses with a route and does not attach a later bare amount" do
    begin_setup
    4.times { household_say("skip", reading.merge(defer_setup: true)) }
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_includes reply, "Setup is paused"
    assert_includes reply, "income"
    assert_includes reply, "Enter my numbers"
    post "/api/v1/mia/messages", params: { message: "2800" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    assert_nil response.parsed_body["mia_action_draft"]
    assert_nil @household.reload.confirmed_setup_fields.find { |field| field == "debt_payment" }
  end

  test "completed setup coaching explains optional prerequisites without restarting setup" do
    begin_setup(primary_income: 3500, fixed_expenses: 1700, flexible_spend: 600)
    assert HouseholdFinance::SetupStatus.new(@household).complete?
    json = household_say("what should i do with my emergency cushion", reading.merge(question: true))
    refute_includes json.dig("assistant_message", "content"), "Still to add:"
    refute_includes json.dig("assistant_message", "content"), "Next setup question:"
  end

  test "an unread first setup message names the manual route before the CTA" do
    post "/api/v1/mia/messages", params: { message: "cruz house" }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Enter my numbers"
    assert_nil response.parsed_body["mia_action_draft"]
    refute HouseholdFinance::SetupStatus.new(@household).complete?
  end

  test "a question after skipping income returns to the currently asked fixed question" do
    begin_setup
    household_say("skip", reading.merge(defer_setup: true))
    json = household_say("What is a sinking fund?", reading.merge(question: true))
    assert_nil json["mia_action_draft"]
    assert_includes json.dig("assistant_message", "content"), HouseholdFinance::MiaSetupGuide.question_message("fixed_expenses", resume: true)
    refute_includes json.dig("assistant_message", "content"), HouseholdFinance::MiaSetupGuide.question_message("primary_income", resume: true)
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

  test "an unknown purchase amount during setup asks instead of creating a failing draft" do
    begin_setup(primary_income: 4800)
    json = household_say("bought bread at Payless today", reading(facts: [ fact("purchase", "", merchant: "Payless", item: "bread") ]))
    assert_nil json["transaction_draft"]
    assert_nil json["mia_action_draft"]
    assert_match(/amount|how much/i, json.dig("assistant_message", "content"))
  end

  test "a hypothetical movement question receives guidance about enough without a report card" do
    with_reading(reading(facts: [ fact("set_aside", "100") ]).merge(question: true)) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "if i put 100 away today would that be enough" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_empty json.fetch("challenge_chat_cards")
        assert_match(/goal.*comfortably|comfortably.*goal/i, json.dig("assistant_message", "content"))
        refute_match(/Got it|set aside today/i, json.dig("assistant_message", "content"))
      end
    end
  end

  test "every quoted purchase in a setup turn reaches its pending review" do
    begin_setup(primary_income: 4800)
    json = household_say("I spent $12 at Target and $30 at Shell today", reading(facts: [ fact("purchase", "$12", merchant: "Target"), fact("purchase", "$30", merchant: "Shell") ]))
    drafts = @household.transaction_drafts.order(:id)
    assert_equal [ "Target", "Shell" ], drafts.pluck(:merchant)
    assert_equal [ 1200, 3000 ], drafts.pluck(:total_amount_cents)
    assert_includes json.dig("assistant_message", "content"), "2 expense reviews"
    assert_equal 0, HouseholdTransaction.count
  end

  test "reader text exceeding the field limit asks for shortening without truncation" do
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, idempotency_key: SecureRandom.uuid, attributes: { household_name: "Reader household" }).call
    household_say("Help me set up my household", reading)
    goal = "A little breathing room " * 24
    json = household_say(goal, reading(field: "goal", value: goal.strip))
    assert_nil json["mia_action_draft"]
    assert_match(/shorten|500 characters/i, json.dig("assistant_message", "content"))
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

  test "quoted bills and named minimums produce server totals on review cards without purchases" do
    begin_setup(primary_income: 4800)
    json = household_say("rent 1200 and power 300", reading(facts: [ fact("bill", "1200", item: "rent", day: ""), fact("bill", "300", item: "power", day: "") ], field: "fixed", value: "1200 and power 300"))
    assert json["mia_action_draft"]
    assert_nil json["transaction_draft"]
    assert_includes json.dig("assistant_message", "content"), "Rent $1,200 + power $300 = $1,500"
    assert_empty @household.expense_items
    household_say("skip", reading.merge(defer_setup: true))
    household_say("skip", reading.merge(defer_setup: true))
    details = { field: "debt_payment", cadence: "monthly", count: "", partial: true,
      components: [ { source: "visa min 40", amount: "40" }, { source: "jcpenney min 25", amount: "25" } ] }
    json = household_say("visa min 40 and jcpenney min 25", reading.merge(setup_details: details))
    assert_nil json["transaction_draft"]
    assert json["mia_action_draft"]
    assert_includes json.dig("assistant_message", "content"), "Visa $40 + jcpenney $25 = $65"
    assert_empty @household.household_transactions
    refute HouseholdFinance::DebtPortfolio.new(@household).minimum_payment_known?
  end

  test "counted monthly checks get a calculated review while unconverted pay cadence asks for a monthly amount" do
    begin_setup
    details = { field: "primary_income", cadence: "monthly_count", count: "2", partial: false,
      components: [ { source: "2 paychecks of 1400", amount: "1400" } ] }
    json = household_say("2 paychecks of 1400", reading(field: "income", value: "1400").merge(setup_details: details))
    assert json["mia_action_draft"]
    assert_includes json.dig("assistant_message", "content"), "2 × $1,400 = $2,800"
    assert_empty @household.income_sources
    [ [ "my check is 900 twice a month", "900" ], [ "i get 1000 a week", "1000" ] ].each do |message, amount|
      json = household_say(message, reading(field: "income", value: amount))
      assert_nil json["mia_action_draft"], message
      assert_match(/can't assume your monthly take-home income|does not tell me your monthly income/i, json.dig("assistant_message", "content"), message)
    end
    assert_not_nil household_say("we bring in 4650 monthly", reading(field: "income", value: "4650"))["mia_action_draft"]
  end

  test "an unclear amount asks again instead of saying nothing was reported" do
    with_reading(reading(facts: [ fact("set_aside", "1,20") ])) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "saved 1,20 today" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_empty json.fetch("challenge_chat_cards")
        assert_match(/couldn't tell the amount/i, json.dig("assistant_message", "content"))
      end
    end
  end

  test "an asked purchase with saved cash gets an answer instead of a day question" do
    with_reading(reading(facts: [ fact("set_aside", "$75", day: "") ]).merge(question: true)) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "Could I buy a $75 lunch bag? I saved that cash separately from my challenge savings." }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_empty json.fetch("challenge_chat_cards")
        refute_match(/Which day|Got it/i, json.dig("assistant_message", "content"))
      end
    end
  end

  test "a small report with a condition after it still reaches its card" do
    with_reading(reading(facts: [ fact("set_aside", "20") ])) do
      with_savings_runtime do
        post "/api/v1/mia/messages", params: { message: "saved 20 today even if it isnt much" }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
        assert_response :created
        json = response.parsed_body
        assert_equal 1, json.fetch("challenge_chat_cards").length
        assert_match(/Got it: \$20\.00 set aside today/, json.dig("assistant_message", "content"))
      end
    end
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
    %w[none hi rent groceries ya k].each do |message|
      json = household_say(message, reading)
      assert_nil json["mia_action_draft"], message
      assert_includes json.dig("assistant_message", "content"), "What would you like to call"
    end
    json = household_say("idk", reading.merge(defer_setup: true))
    assert_nil json["mia_action_draft"]
    assert_includes json.dig("assistant_message", "content"), "main money goal"
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
  test "R5 current reader care preempts household date clarification and setup without a second read" do
    [ [ "We buried my husband on Tuesday. Could I buy a $200 headstone deposit?", "grief", /sorry for your loss/ ],
      [ "I don't know how much longer I can keep doing this", "crisis", /988/ ] ].each do |message, care, expected|
      json = household_say(message, reading(care: care))
      assert_match expected, json.dig("assistant_message", "content")
      refute_match(/month and year|Next setup question|\$200/, json.dig("assistant_message", "content"))
      assert_nil json["mia_action_draft"]
      assert_nil json["transaction_draft"]
      with_reading(reading(care: care)) do
        with_savings_runtime do
          post "/api/v1/mia/messages", params: { message: message }, headers: { "Authorization" => "Bearer test_token_#{@savings_user.id}" }, as: :json
          assert_response :created
          assert_match expected, response.parsed_body.dig("assistant_message", "content")
          assert_empty Array(response.parsed_body["challenge_chat_cards"])
        end
      end
    end
  end

  test "R5 model clarification is guarded and falls back for approval invented contact and outage" do
    resolver = HouseholdFinance::MiaIntentResolver
    old = resolver.instance_method(:call)
    guard = Mia::ReplyGuard.method(:call)
    [ [ "You can buy it, and I've saved it. Which color?", "purchase_approval" ],
      [ "Call 671-555-0100 for the Bank of Guam program. Which one?", "invented_fact" ],
      [ "Which account did you mean?", "provider_failure" ],
      [ "Which account did you mean?", "sensitive_moment" ] ].each do |text, reason|
      resolver.define_method(:call) do
        self.class::Result.new(intent: "coaching", confidence: 0.95, continuation: false,
          resolved_message: "that thing we talked about", needs_clarification: true, clarification: text,
          topic: { type: "coaching" }, action: { type: "none" }, read_only_plan: {}, source: "model")
      end
      Mia::ReplyGuard.define_singleton_method(:call) { |**_| Mia::ReplyGuard::Result.new([ reason ]) }
      json = household_say("What about that thing we talked about?", reading)
      assert_equal "I want to make sure I have the right request. Please name the category, amount, and month you want to change. Nothing changed yet.", json.dig("assistant_message", "content")
      assert_nil json["mia_action_draft"]
    end
  ensure
    resolver.define_method(:call, old)
    Mia::ReplyGuard.define_singleton_method(:call, guard)
  end

  test "R5 a hardship history never hides a later month question or recovered purchase" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "R5 household", primary_goal: "Cushion", primary_income: "4800",
      fixed_expenses: "2100", flexible_spend: "900", debt_payment: "350").call
    care = household_say("I lost my job yesterday.", reading(care: "hardship")).dig("assistant_message", "content")
    assert_match(/sounds hard/, care)
    answer = household_say("The rent. How much is left in my plan this month?", reading).dig("assistant_message", "content")
    refute_equal care, answer
    assert_match(/plan|November/i, answer)
    assert_match(/\$[\d,]+/, answer)
    refute_match(/What feels most urgent|when you're ready/, answer)
    household_say("I started a new job last month and things are steady now", reading)
    answer = household_say("Can I get a $40 pair of shoes?", reading).dig("assistant_message", "content")
    refute_equal care, answer
    refute_match(/What feels most urgent|when you're ready/, answer)
    assert_match(/\$40/, answer)
  end
  test "R5 CR food floor survives a none reading before a purchase comparison" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "R5 food", primary_goal: "Cushion", primary_income: "4800", fixed_expenses: "2100", flexible_spend: "900", debt_payment: "350").call
    json = household_say("We have no food this week. Can I buy a $300 TV?", reading)
    answer = json.dig("assistant_message", "content")
    assert_match(/food|eat/, answer)
    refute_match(/\$300|would leave|plan has/i, answer)
    assert_nil json["mia_action_draft"]
    assert_nil json["transaction_draft"]
  end
end
