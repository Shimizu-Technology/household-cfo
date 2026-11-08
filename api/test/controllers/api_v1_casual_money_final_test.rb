require "test_helper"
require_relative "../support/participant_reader_test_support"
require_relative "../support/savings_challenge_test_support"

class ApiV1CasualMoneyFinalTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  include SavingsChallengeTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 6, 12)
    @household_user = User.create!(clerk_id: "w26_#{SecureRandom.hex(8)}", email: "w26-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    setup_savings_context
    with_savings_runtime { savings_enroll; savings_plan; savings_approve(savings_draft(2500)) }
  end

  teardown { travel_back }

  test "Day 1 gives the same spending refusal only once" do
    body = send_message("spent 14.50 at kin yesterday and saved nothing", reading(facts: [
      fact("purchase", "14.50", "yesterday", "kin"), fact("nothing_saved", "", "yesterday")
    ]))
    content = body.fetch("assistant_message").fetch("content")
    assert_includes content, "Nothing was saved."
    assert_equal 1, content.scan("Nothing was saved.").length
  end

  def reading(**extra)
    { care: "none", facts: [], question: false, setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }.merge(extra)
  end

  def fact(kind, amount, day, merchant = "")
    { kind: kind, amount: amount, day: day, merchant: merchant, item: "" }
  end

  def send_message(text, data, challenge: true)
    headers = { "Authorization" => "Bearer test_token_#{challenge ? @savings_user.id : @household_user.id}" }
    headers["X-Cohort-Id"] = @savings_cohort.id.to_s if challenge
    with_participant_reader_response(data) do
      post "/api/v1/mia/messages", params: { message: text, request_id: SecureRandom.uuid }, headers: headers, as: :json
    end
    assert_response :created
    response.parsed_body
  end


  def read_message(text, data)
    HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_) { data.to_json })
  end

  def resolver(text, data, **extra)
    context = { participant_reading: read_message(text, data), setup_status: { complete: true, missing_fields: [] },
      calendar: { today: "2026-11-06" }, conversation: {}, active_goals: [ { id: 1, label: "Car" }, { id: 2, label: "Trip" } ] }.merge(extra)
    HouseholdFinance::MiaIntentResolver.new(user_message: text, context: context, api_key: "")
  end

  test "item 1 question goals and substring labels cannot select an update" do
    result = resolver("can i make my Car goal 600?", reading(question: true, goal_change: { amount: "600" })).participant_goal_result
    assert_nil result
    result = resolver("make the card goal 600", reading(goal_change: { amount: "600" })).participant_goal_result
    refute result.actionable?
    result = resolver("make the Car goal 600", reading(goal_change: { amount: "600" })).participant_goal_result
    assert_equal 1, result.action[:goal_id]
  end

  test "item 2 participant handlers respect read only and month routing" do
    text = "Don't change anything, I spent 20 at Payless today, how does it affect my budget?"
    result = resolver(text, reading(question: true, facts: [ fact("purchase", "20", "today", "Payless") ])).call
    refute result&.actionable?
    text = "make my Car goal 600, how am i doing"
    result = resolver(text, reading(question: true, goal_change: { amount: "600" })).call
    refute_equal "participant_reader", result&.source
    text = "spent 20 at ross today, how am i doing"
    result = resolver(text, reading(question: true, facts: [ fact("purchase", "20", "today", "ross") ])).call
    refute_equal "participant_reader", result&.source
  end

  test "item 3 purchase dates stay inside their own source spans" do
    text = "spent 20 at ross yesterday and 30 at kmart on monday"
    facts = [ fact("purchase", "20", "", "ross").merge(source_text: "spent 20 at ross yesterday"),
      fact("purchase", "30", "", "kmart").merge(source_text: "30 at kmart on monday") ]
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.new(2026, 10, 1), Date.new(2026, 12, 31), Date.new(2026, 11, 6))
    intake = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: read_message(text, reading(facts: facts)))
    intake.call
    assert_equal [ "2026-11-02", "2026-11-05" ], intake.intakes.map { |input| input[:local_on] }.sort
    result = resolver(text, reading(facts: facts)).participant_purchase_result
    assert result.actionable?, result.inspect
    assert_equal [ "2026-11-05", "2026-11-02" ], result.write_plan[:actions].map { |a| a[:action][:occurred_on] }
    text = "spent 30 at spirit halloween and saved 20 yesterday"
    facts = [ fact("purchase", "30", "halloween", "spirit halloween").merge(source_text: "spent 30 at spirit halloween"), fact("set_aside", "20", "yesterday") ]
    result = resolver(text, reading(facts: facts)).participant_purchase_result
    assert_equal "2026-11-06", result.action[:occurred_on]
    facts.first[:day] = "yesterday"
    result = resolver(text, reading(facts: facts)).participant_purchase_result
    refute_equal "2026-11-05", result.action[:occurred_on]
  end

  test "item 4 short weekday inside a merchant is not a date" do
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.new(2026, 10, 1), Date.new(2026, 12, 31), Date.new(2026, 11, 6))
    result = HouseholdFinance::PurchaseReportParser.new(calendar, message: "spent 20 at Sun Pharmacy").call
    assert result.found?, result.inspect
    assert_equal "Sun Pharmacy", result.report[:purchases].sole[:merchant]
    assert_equal "2026-11-06", result.report[:purchases].sole[:purchased_on]
    %w[sat wed tues].each do |day|
      result = HouseholdFinance::PurchaseReportParser.new(calendar, message: "spent 20 at ross #{day}").call
      assert result.found?, day
      refute_equal "2026-11-06", result.report[:purchases].sole[:purchased_on]
      source_day = HouseholdFinance::ParticipantReportDay.call(day: "", message: "spent 20 at ross #{day}", today: calendar.local_today)
      assert_equal result.report[:purchases].sole[:purchased_on], source_day.date&.iso8601
    end
  end

  test "item 5 savings correction preserves a separate completed fact" do
    text = "oops the 25 i saved was really 20 and saved 10 today"
    body = send_message(text, reading(savings_correction: { old_amount: "25", new_amount: "20", day: "" },
      facts: [ fact("set_aside", "10", "today").merge(source_text: "saved 10 today") ]))
    cards = body["challenge_chat_cards"]
    assert_equal [ 1000, 2000 ], cards.map { |c| c.dig("input", "amount_cents") }.sort
    assert_equal 2500, @savings_enrollment.savings_entries.first.current_approved_version.signed_cents
  end

  test "item 6 date continuation stages its update until locked persistence and retries" do
    body = send_message("spent 19 at flea market recently", reading(facts: [ fact("purchase", "19", "recently", "flea market") ]))
    assert body["challenge_chat_card"], body.inspect
    card = SavingsChatCard.find(body.dig("challenge_chat_card", "id"))
    session = card.chat_message.chat_session
    turn = SavingsChallenge::ChatTurn.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment,
      session: session, message: "nov 6", persona: nil, history: [], reading: read_message("nov 6", reading)).call
    assert card.reload.input["date_required"], "call must not persist the date"
    assistant = card.chat_message
    @savings_household.with_lock do
      ActiveRecord::Base.transaction(requires_new: true) do
        turn.persist!(assistant)
        assert_equal "2026-11-06", card.reload.input["local_on"]
        raise ActiveRecord::Rollback
      end
      assert card.reload.input["date_required"]
      turn.persist!(assistant)
    end
    assert_equal "2026-11-06", card.reload.input["local_on"]
    assert_equal 1, SavingsChatCard.where(chat_message: assistant).count
  end

  test "item 7 weekly pace belongs to chosen amount and negated changes stay blocked" do
    text = "make my goal 600 instead of 20 a week"
    body = send_message(text, reading(goal_change: { amount: "600" }))
    assert_equal 60000, body.dig("challenge_chat_card", "input", "target_cents")
    assert_nil body.dig("challenge_chat_card", "input", "weekly_cents")
    body = send_message("make my goal 20 a week", reading(goal_change: { amount: "20" }))
    assert_equal 25_714, body.dig("challenge_chat_card", "input", "target_cents")
    body = send_message("im not going to change my goal to 600", reading(goal_change: { amount: "600" }))
    assert_nil body["challenge_chat_card"]
  end

  test "item 8 ordered purchases survive future purpose and all rejections are retained" do
    [ "last weekend", "" ].each do |day|
      text = "ordered 40 at Payless #{day} for next week's party"
      result = read_message(text, reading(facts: [ fact("purchase", "40", day, "Payless") ]))
      assert_equal 1, result.facts.length, day
    end
    text = "going to order 40 at Payless next week"
    assert_empty read_message(text, reading(facts: [ fact("purchase", "40", "next week", "Payless") ])).facts
    parser = SavingsChallenge::ChatIntake.new(@savings_enrollment, message: "", reading: read_message("", reading))
    structured = { kind: :before_start, movement: "set_aside" }
    fallback = { kind: :future, movement: "purchase" }
    parser.instance_variable_set(:@rejections, [ structured ])
    parser.instance_variable_set(:@rejection, fallback)
    assert_equal [ structured, fallback ], parser.rejections
    parser.instance_variable_set(:@rejection, structured)
    assert_equal [ structured ], parser.rejections
  end

  test "a corrected amount the reader also reports makes no second savings card" do
    body = send_message("oops the 25 i saved was really 20", reading(savings_correction: { old_amount: "25", new_amount: "20", day: "" },
      facts: [ fact("set_aside", "20", "") ]))
    assert_equal 1, body.fetch("challenge_chat_cards").length
  end

  test "a further mention of the corrected amount stays a separate savings card" do
    body = send_message("change the 25 to 20 and i saved 20 today", reading(savings_correction: { old_amount: "25", new_amount: "20", day: "" },
      facts: [ fact("set_aside", "20", "today") ]))
    assert_equal 2, body.fetch("challenge_chat_cards").length
  end

  test "stated funding is not taken as the price of a purchase" do
    body = send_message("Could I get a couch? I have $500 saved", reading(question: true), challenge: false)
    refute_match(/\$500 couch|\$500 purchase/i, body.dig("assistant_message", "content"))
  end

  test "a report alongside a saved total question keeps its card" do
    body = send_message("how much did i save so far, put 20 away today", reading(question: true, facts: [ fact("set_aside", "20", "today") ]))
    assert_equal 1, body.fetch("challenge_chat_cards").length
  end

  test "a period savings question is not answered with the all-time total" do
    [ "how much did i save this month", "how much have i saved in october", "how much did i save last week" ].each do |text|
      assert_not SavingsChallenge::CoachAnswerer.saved_total_question?(text), text
    end
    assert SavingsChallenge::CoachAnswerer.saved_total_question?("how much did i save so far")
  end
end
