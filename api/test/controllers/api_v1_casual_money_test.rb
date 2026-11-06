require "test_helper"
require_relative "../support/participant_reader_test_support"
require_relative "../support/savings_challenge_test_support"

class ApiV1CasualMoneyTest < ActionDispatch::IntegrationTest
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

  test "household completed reports use the reader and local weekday on the card and after reload" do
    { "spent 20 at ross last friday" => [ "20", "last friday", "ross", "2026-10-30" ],
      "spent $30 at payless on monday" => [ "$30", "on monday", "payless", "2026-11-02" ],
      "just got back from payless, dropped like 45 on groceries" => [ "45", "", "payless", "2026-11-06" ] }.each do |text, (amount, day, merchant, date)|
      body = send_message(text, reading(facts: [ fact("purchase", amount, day, merchant) ]), challenge: false)
      draft = body.fetch("transaction_draft")
      assert draft, body.inspect
      assert_equal date, TransactionDraft.find(draft.fetch("id")).reload.occurred_on.iso8601
      refute_includes body.dig("assistant_message", "content"), "Only already incurred"
    end
  end

  test "casual challenge goal and savings correction prepare reviews only" do
    body = send_message("make my goal 600", reading(goal_change: { amount: "600" }))
    assert_equal 60_000, body.dig("challenge_chat_card", "input", "target_cents")
    assert_equal 50_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    body = send_message("set my goal to $650", reading(goal_change: { amount: "$650" }))
    assert_equal 65_000, body.dig("challenge_chat_card", "input", "target_cents")
    [ "oops the 25 i saved was really 20", "change the 25 to 20" ].each do |text|
      body = send_message(text, reading(savings_correction: { old_amount: "25", new_amount: "20", day: "" }))
      assert_equal 2000, body.dig("savings_intake", "amount_cents")
      assert body.dig("savings_intake", "correction")
      assert_equal 2500, @savings_enrollment.savings_entries.sole.reload.current_approved_version.signed_cents
    end
  end

  test "household goal target uses the same reading and remains a pending review" do
    household = HouseholdFinance::WorkspaceResolver.new(@household_user).household
    HouseholdFinance::SetupUpdater.new(household, household_name: "Synthetic home", primary_goal: "Build a cushion",
      primary_income: "4800", fixed_expenses: "2400", flexible_spend: "700", debt_payment: "0").call
    goal = household.goals.create!(label: "Cushion", goal_type: "savings", target_amount_cents: 50_000)
    body = send_message("make my goal 600", reading(goal_change: { amount: "600" }), challenge: false)
    assert body["mia_action_draft"], body.inspect
    assert_equal 50_000, goal.reload.target_amount_cents
    assert_includes body["mia_action_draft"].to_json, "60000"
    body = send_message("650", reading(goal_change: { amount: "650" }), challenge: false)
    assert body["mia_action_draft"], body.inspect
    assert_includes body["mia_action_draft"].to_json, "65000"
    assert_equal 50_000, goal.reload.target_amount_cents
  end

  test "raise plus purchase acknowledges both and never asks for the known price again" do
    household = HouseholdFinance::WorkspaceResolver.new(@household_user).household
    HouseholdFinance::SetupUpdater.new(household, household_name: "Synthetic home", primary_goal: "Build a cushion",
      primary_income: "4800", fixed_expenses: "2400", flexible_spend: "700", debt_payment: "0").call
    text = "got a raise!! im at 5600 a month now. can i get a 700 phone?"
    body = send_message(text, reading(question: true, facts: [ fact("income", "5600", "") ], purchase_question: { amount: "700", item: "phone" }), challenge: false)
    reply = body.dig("assistant_message", "content")
    assert_includes reply, "income update"
    assert_includes reply, "$700"
    refute_includes reply, "700 700"
    refute_includes reply, "What does the item cost"
    assert_nil body["transaction_draft"]
  end

  test "valid review and rejected or imprecise amounts are all mentioned" do
    body = send_message("saved 10 today and like 5ish yesterday", reading(unclear_amount: true, facts: [ fact("set_aside", "10", "today") ]))
    assert_equal 1000, body.dig("savings_intake", "amount_cents")
    assert_includes body.dig("assistant_message", "content"), "other amounts"
    body = send_message("saved 10 today and 30 tomorrow", reading(facts: [ fact("set_aside", "10", "today"), fact("set_aside", "30", "tomorrow") ]))
    assert_equal 1000, body.dig("savings_intake", "amount_cents")
    assert_includes body.dig("assistant_message", "content"), "hasn't happened"
    assert_includes body.dig("assistant_message", "content"), "$10.00"
  end

  test "mixed missing and future dates are both explained" do
    body = send_message("saved 17 and spent 18 tomorrow", reading(facts: [ fact("set_aside", "17", ""), fact("purchase", "18", "tomorrow") ]))
    reply = body.dig("assistant_message", "content")
    assert_includes reply, "$17.00"
    assert_includes reply, "hasn't happened"
  end

  test "separate purchase source spans never borrow an adjacent movement or another price" do
    text = "spent 20 at ross today and spent 30 at shell today and put 50 in savings"
    facts = [ fact("purchase", "20", "today", "ross").merge(source_text: "spent 20 at ross today"),
      fact("purchase", "30", "today", "shell").merge(source_text: "spent 30 at shell today") ]
    before = TransactionDraft.count
    send_message(text, reading(facts: facts), challenge: false)
    drafts = TransactionDraft.order(:id).last(2)
    assert_equal before + 2, TransactionDraft.count
    assert_equal [ [ "ross", 2000 ], [ "shell", 3000 ] ], drafts.map { |draft| [ draft.merchant, draft.total_amount_cents ] }
  end

  test "overlapping purchase source quotes beside savings ask instead of reusing the first price" do
    text = "spent 20 at ross today and spent 30 at shell today and put 50 in savings"
    facts = [ fact("purchase", "20", "today", "ross").merge(source_text: text),
      fact("purchase", "30", "today", "shell").merge(source_text: text) ]
    assert_no_difference "TransactionDraft.count" do
      body = send_message(text, reading(facts: facts), challenge: false)
      assert_nil body["transaction_draft"]
      assert_includes body.dig("assistant_message", "content"), "each purchase separately"
    end
  end

  test "savings rejected before enrollment is called savings and undated amounts all get questions" do
    body = send_message("saved 40 yesterday", reading(facts: [ fact("set_aside", "40", "yesterday") ]))
    assert_includes body.dig("assistant_message", "content"), "yesterday's savings"
    body = send_message("saved 17 and put away 23", reading(facts: [ fact("set_aside", "17", ""), fact("set_aside", "23", "") ]))
    assert_includes body.dig("assistant_message", "content"), "$17.00"
    assert_includes body.dig("assistant_message", "content"), "$23.00"
  end
end
