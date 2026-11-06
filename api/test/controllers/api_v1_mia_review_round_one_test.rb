require "test_helper"
require_relative "../support/participant_reader_test_support"

class ApiV1MiaReviewRoundOneTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    @user = User.create!(clerk_id: "review_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end
  teardown { travel_back }

  test "setup recovery preserves incurred purchases and unrelated questions" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz", primary_goal: "Pay Visa").call
    ask(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    ask("I spent $12 at Target today")
    assert response.parsed_body["transaction_draft"], reply
    [ "My husband left me last night", "I need to talk to someone", "How do I contact my coach?", "How can I reach my coach?", "What is a sinking fund?", "Can I afford a $300 stroller?" ].each do |message|
      ask(message)
      refute_match(/\ANext setup question:/, reply, message)
      refute_match(/I haven't added that to your setup/, reply, message)
      assert_nil response.parsed_body["mia_action_draft"], message
    end
  end

  test "names exclude sentences and keep long family names" do
    ask(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    [ "My mom is in the hospital and the kids have not eaten since yesterday morning at all", "I need help with my family", "My husband left me last night" ].each do |message|
      ask(message)
      assert_nil response.parsed_body["mia_action_draft"], message
    end
    ask("Santos Cruz Dela Rosa extended family household")
    assert response.parsed_body["mia_action_draft"], reply
  end

  test "five essentials stay complete with unknown and archived debt minimums" do
    five_answers
    assert HouseholdFinance::SetupStatus.new(@household).complete?
    assert_includes HouseholdFinance::SetupStatus.new(@household).missing_field_keys, "debt_payment"
    debt = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 10000, minimum_payment_cents: 5000)
    debt.update!(active: false, archived_at: Time.current)
    assert HouseholdFinance::SetupStatus.new(@household.reload).complete?
    get "/api/v1/workspace", headers: headers
    assert_response :success
    assert response.parsed_body.dig("workspace", "setup_complete")
  end

  test "hardship anywhere outranks a purchase across varied sentences" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    [ "I haven't eaten in two days", "I've been skipping meals so the kids could eat", "I skip meals to feed my kids", "My landlord just evicted us", "I'm scared we won't make rent", "We just got evicted yesterday", "We're being evicted", "Our landlord is evicting us", "We received an eviction notice", "I'm worried about covering the rent next week" ].each do |hardship|
      ask("Can I afford a $300 stroller? #{hardship}")
      assert_match(/food|housing|essential|eat|meals/i, reply, hardship)
      assert_match(/coach|trusted/i, reply, hardship)
      refute_match(/The \$300 purchase|Scenario only|readiness color/, reply, hardship)
    end
  end

  test "budget synonyms before plan and future year keep coverage and unknown honest" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    [ "What is my budget for October?", "How much is left in my budget for August?" ].each do |message|
      ask(message)
      assert_match(/plan starts in November 2026|no plan.*(?:August|October)|(?:August|October).*no plan/i, reply, message)
      refute_match(/spent so far \$0|saved monthly plan \$900/, reply)
    end
    ask("Show my budget for this month")
    refute_match(/spent so far \$0/, reply)
    [ "Can I afford a $300 stroller in January?", "How am I doing in January 2027?" ].each do |message|
      ask(message)
      assert_match(/2027.*plan|plan.*2027/, reply)
      refute_match(/Still to add: your main income|Scenario only/, reply)
    end
    refute @household.budget_years.exists?(year: 2027)
  end

  test "purchase variants avoid internal wording and acknowledge another question" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    [ "Should I buy a $300 stroller?", "I want to buy a $300 stroller", "Can I afford a stroller?" ].each do |message|
      ask(message)
      refute_match(/Plaid-derived|liquid account picture|Scenario only|readiness color|plan figure for Stroller/, reply)
    end
    ask("Can I afford a $300 stroller? What is a sinking fund?")
    assert_match(/sinking fund/i, reply)
    assert_match(/set aside|planned|save/i, reply)
    ask("Can I afford a $300 stroller? How can I reach my coach?")
    assert_match(/coach.*contact details|contact details.*coach/i, reply)
    ask("Can I afford a $300 stroller? What about school next spring?")
    assert_includes reply, "school next spring"
  end

  test "past purchase dates never use the current month" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    [ "Can I afford a $300 stroller last month?", "Could I have bought a $300 stroller on October 1?" ].each do |message|
      ask(message)
      assert_match(/October 2026/, reply, message)
      refute_match(/November 2026 plan leaves/, reply)
    end
  end

  test "debt replies support none and natural amounts but never overwrite individual minimums" do
    five_answers
    ask(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    ask("We pay about $150 a month")
    assert response.parsed_body["mia_action_draft"], reply
    ask("none")
    assert response.parsed_body["mia_action_draft"], reply
    ask("I don't know")
    assert_match(/couldn.t read.*try again/i, reply)
    assert_nil response.parsed_body["mia_action_draft"]
    refute_match(/Next setup question/i, reply)
    @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 10000, minimum_payment_cents: 5000)
    @household.household_profile.update!(debt_tracking_mode: "individual")
    ask("No debt payments")
    assert_nil response.parsed_body["mia_action_draft"], reply
    assert_match(/Visa|individual|minimum/i, reply)
    @household.household_profile.update!(debt_tracking_mode: "summary")
    ask("No debt payments")
    assert_nil response.parsed_body["mia_action_draft"], reply
    assert_match(/debt.*minimum|minimum.*debt/i, reply)
  end

  test "legacy purchase coaching keeps every figure deterministic" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    calls = []
    original = HouseholdFinance::MiaNarrator.instance_method(:call)
    HouseholdFinance::MiaNarrator.define_method(:call) do
      calls << true
      "Model-owned figures must never replace the purchase answer."
    end
    [ [ "Can I buy a $500 purse?", "$500 purse" ], [ "Should I spend $75 on a handbag?", "$75 purse" ], [ "Can I buy a $120 purse for school?", "baseline need" ] ].each do |message, expected|
      ask(message)
      refute_includes reply, "Model-owned figures", message
      assert_includes reply, expected, message
    end
    assert_empty calls
  ensure
    HouseholdFinance::MiaNarrator.define_method(:call, original) if original
  end

  test "late review purchase corrections and selected periods keep their own facts" do
    five_answers
    HouseholdFinance::SetupUpdater.new(@household, debt_payment: "95").call
    ask("Can I buy a $300 stroller?", month: 12, year: 2026)
    assert_includes reply, "December 2026"
    [ "Can I afford a $300 stroller? No, it costs $400", "Should I buy a $300 stroller? Sorry, I meant $400" ].each do |message|
      ask(message)
      assert_match(/\$400.*\$1,005/, reply, message)
      assert_nil response.parsed_body["mia_action_draft"]
      assert_nil response.parsed_body["transaction_draft"]
    end
    ask("Can I buy a $300 stroller? Actually, the price is $400 or $450")
    assert_match(/which.*price/i, reply)
    ask("Can I afford a $300 stroller? I missed meals so my kids could eat, but my food budget is empty")
    assert_match(/food.*today|eat.*today/i, reply)
    refute_includes reply, "The $300 purchase"
  end

  private
  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }
  def ask(message, **period)
    post "/api/v1/mia/messages", params: { message: message }.merge(period), headers: headers, as: :json
    assert_response :created
  end
  def reply = response.parsed_body.dig("assistant_message", "content")
  def five_answers
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz household", primary_goal: "Pay off Visa", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900").call
  end
end
