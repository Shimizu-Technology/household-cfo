require "test_helper"
require_relative "../support/participant_reader_test_support"
require_relative "../support/savings_challenge_test_support"

class ApiV1CasualMoneyRoundTwoTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  include SavingsChallengeTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 6, 12)
    @household_user = User.create!(clerk_id: "w26_#{SecureRandom.hex(8)}", email: "w26-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    setup_savings_context
    with_savings_runtime { savings_enroll; savings_plan; savings_approve(savings_draft(2500)) }
  end

  teardown { travel_back }

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

  test "short days and periods resolve on both paths" do
    { "last night" => "2026-11-05", "this morning" => "2026-11-06", "this afternoon" => "2026-11-06", "this evening" => "2026-11-06", "yesterday afternoon" => "2026-11-05", "yesterday morning" => "2026-11-05", "saturday night" => "2026-10-31", "sat" => "2026-10-31", "yest" => "2026-11-05", "wed" => "2026-11-04", "tues" => "2026-11-03" }.each do |day, expected|
      text = "paid 19 at the flea market #{day}"
      body = send_message(text, reading(facts: [ fact("purchase", "19", day, "flea market") ]), challenge: false)
      assert_equal expected, body.dig("transaction_draft", "occurred_on"), text
      calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.new(2026, 10, 1), Date.new(2026, 12, 31), Date.new(2026, 11, 6))
      r = HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_) { reading(facts: [ fact("purchase", "19", day, "flea market") ]).to_json })
      intake = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: r)
      intake.call
      assert_equal expected, intake.intakes.sole.dig(:purchases, 0, :purchased_on), text
    end
  end

  test "date clarification retains the purchase and accepts a day answer" do
    [ "wednesday", "nov 4" ].each_with_index do |answer, index|
      amount = (19 + index).to_s
      text = "paid #{amount} at flea market on payday"
      body = send_message(text, reading(facts: [ fact("purchase", amount, "on payday", "flea market") ]), challenge: false)
      assert_includes body.dig("assistant_message", "content"), "on payday"
      assert_includes body.dig("assistant_message", "content").downcase, "which day"
      body = send_message(answer, reading, challenge: false)
      assert_equal "2026-11-04", body.dig("transaction_draft", "occurred_on"), body.inspect
      assert_equal amount.to_i * 100, body.dig("transaction_draft", "amount_cents")
    end
  end

  test "challenge date answer completes the same pending card" do
    body = send_message("spent 19 at flea market recently", reading(facts: [ fact("purchase", "19", "recently", "flea market") ]))
    card = body["challenge_chat_card"]
    assert card
    assert_includes body.dig("assistant_message", "content"), "recently"
    body = send_message("nov 6", reading)
    assert_equal card["id"], body.dig("challenge_chat_card", "id")
    assert_equal "2026-11-06", body.dig("challenge_chat_card", "input", "purchases", 0, "purchased_on")
    assert_equal 0, SavingsDailyPurchaseVersion.count
  end

  test "completed saving survives a future purpose and a person's name is not a plan" do
    [ "set aside 30 today for next month", "stashed 30 today for next week", "put 30 away today for next week" ].each do |text|
      body = send_message(text, reading(facts: [ fact("set_aside", "30", "today") ]))
      assert_equal 3000, body.dig("savings_intake", "amount_cents"), text
    end
    body = send_message("saving 30 next week", reading(facts: [ fact("set_aside", "30", "next week") ]))
    assert_nil body["savings_intake"]
    body = send_message("paid will 40 to cut the grass on tues", reading(facts: [ fact("purchase", "40", "on tues", "will") ]), challenge: false)
    assert_equal 4000, body.dig("transaction_draft", "amount_cents")
  end

  test "explicit non writes cannot become cards even when the reader misreads them" do
    [ "i didnt spend 20 at ross", "dont make a card, i spent 20 at ross today" ].each do |text|
      body = send_message(text, reading(facts: [ fact("purchase", "20", "", "ross") ]), challenge: false)
      assert_nil body["transaction_draft"], text
      assert_nil body["mia_action_draft"], text
    end
    [ "im not changing my goal to 600", "is 600 a good goal" ].each do |text|
      body = send_message(text, reading(goal_change: { amount: "600" }))
      assert_nil body["challenge_chat_card"], text
    end
    body = send_message("should i change the 25 to 20", reading(savings_correction: { old_amount: "25", new_amount: "20", day: "" }))
    assert_nil body["savings_intake"]
  end

  test "weekly goals zero targets and unchanged corrections are honest" do
    body = send_message("make my goal 20 a week", reading(goal_change: { amount: "20" }))
    assert_equal 25_714, body.dig("challenge_chat_card", "input", "target_cents")
    body = send_message("make my goal 0", reading(goal_change: { amount: "0" }))
    assert_nil body["challenge_chat_card"]
    body = send_message("change the 25 to 25", reading(savings_correction: { old_amount: "25", new_amount: "25", day: "" }))
    assert_nil body["savings_intake"]
  end

  test "halloween names and costumes do not date purchases and savings are acknowledged" do
    [ "spent 30 at spirit halloween", "spent 30 at ross for a halloween costume" ].each do |text|
      result = HouseholdFinance::ParticipantReportDay.call(day: "", message: text, today: Date.new(2026, 10, 15))
      assert_equal :missing, result.state, text
    end
    text = "spent 20 at ross today and put 50 in savings"
    body = send_message(text, reading(facts: [ fact("purchase", "20", "today", "ross"), fact("set_aside", "50", "") ]), challenge: false)
    assert body["transaction_draft"]
    assert_includes body.dig("assistant_message", "content").downcase, "savings"
    assert_includes body.dig("assistant_message", "content"), "$50"
  end

  test "a separate completed purchase survives a negated earlier purchase" do
    text = "i didnt spend 20 at ross but spent 30 at shell today"
    body = send_message(text, reading(facts: [ fact("purchase", "30", "today", "shell").merge(source_text: "spent 30 at shell today") ]), challenge: false)
    assert_equal 3000, body.dig("transaction_draft", "amount_cents")
  end

  test "multiple purchases still acknowledge separate savings" do
    text = "spent 20 at ross today and spent 30 at shell today and put 50 in savings"
    facts = [ fact("purchase", "20", "today", "ross").merge(source_text: "spent 20 at ross today"), fact("purchase", "30", "today", "shell").merge(source_text: "spent 30 at shell today"), fact("set_aside", "50", "") ]
    body = send_message(text, reading(facts: facts), challenge: false)
    assert_includes body.dig("assistant_message", "content"), "$50"
    assert_includes body.dig("assistant_message", "content"), "savings"
  end

  test "merchant labels preserve participant spelling" do
    [ "7-eleven", "K-Mart", "GPA", "CVS", "McDonald's" ].each do |name|
      assert_equal name, HouseholdFinance::PurchaseQuestionText.merchant_label(name)
    end
  end

  test "reader off retains named bills full calendar dates and halloween stores" do
    [ "I paid the $90 water bill.", "I spent $30 at Ross on November 2, 2026.", "I spent $5 at Spirit Halloween yesterday." ].each do |text|
      body = send_message(text, nil, challenge: false)
      assert body["transaction_draft"], "#{text}: #{body.dig('assistant_message', 'content')}"
    end
  end
end
