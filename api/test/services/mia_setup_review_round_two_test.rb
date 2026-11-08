require "test_helper"

class MiaSetupReviewRoundTwoTest < ActiveSupport::TestCase
  def parsed(text, field: "fixed_expenses", correction: false, components: nil, **extra)
    components ||= text.split(" and ").filter_map { |part| { source: part, amount: part[/\d[\d,]*(?:\.\d+)?/] } if part.match?(/\d/) }
    HouseholdFinance::ParticipantMessageReader.new(message: text, setup_field: field, pending_field: field).send(:validate,
      { care: "none", question: false, correction: correction, facts: [], setup_answer: { field: "none", value: "" }, spending_preferences: [],
        setup_details: { field: field, cadence: field == "primary_income" ? "monthly_count" : "monthly", count: field == "primary_income" ? "2" : "", components: components, partial: true } }.merge(extra).deep_stringify_keys)
  end

  def calculate(text, **options)
    HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text, **options), field: options.fetch(:field, "fixed_expenses")).call
  end

  def prior
    calculate("rent 1080 and power 220")
  end

  test "model off bills at an open fixed question stay setup rather than purchase" do
    text = "i pay rent 1200"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: text, setup_field: "fixed_expenses", api_key: "")
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "fixed_expenses" } ] },
      conversation: { active_thread: {}, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("fixed_expenses") } ] }
    }).call
    refute_equal "transaction_report", result.intent
    refute_equal "create_transaction_draft", result.action[:type]
    assert_match(/Enter my numbers|monthly|total/i, result.clarification)
  end

  test "a pending bill list retains parts when adding water and correcting power" do
    addition = HouseholdFinance::MiaSetupCalculation.new(message: "oh and water is 60", reading: parsed("oh and water is 60"), prior: prior, field: "fixed_expenses").call
    assert_equal "1360.0", addition[:value]
    assert_equal 3, addition[:components].length
    correction = HouseholdFinance::MiaSetupCalculation.new(message: "wait power is 250", reading: parsed("wait power is 250", correction: true), prior: addition, field: "fixed_expenses").call
    assert_equal "1390.0", correction[:value]
    assert_equal 3, correction[:components].length
    assert_includes correction[:description], "Rent $1,080 + power $250 + water $60 = $1,390"
  end

  test "Ruby preserves pending parts even when the reader loses a component" do
    text = "wait power is 250"
    service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text, correction: true, components: [], setup_answer: { field: "fixed", value: "250" }), field: "fixed_expenses", prior: prior)
    assert_equal "1330.0", service.call[:value]
  end

  test "working names each part and does not pretend a single item is a sum" do
    assert_includes calculate("rent 1200 and power 300")[:description], "Rent $1,200 + power $300 = $1,500"
    single = calculate("rent 1150")[:description]
    assert_includes single, "Rent $1,150"
    refute_includes single, "="
  end

  test "misread ranges fractions years dates negation cadence and past bills ask instead of summing" do
    [ "rent 1200-1300", "rent half of 1200", "power 20% of that", "rent since 2024", "rent due nov 20", "not the 300 storage", "rent 100 a week", "power was 300 last month", "rent 1200 and power is like 20% of that", "rent 1200 and power 300 total 1500" ].each do |text|
      service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text), field: "fixed_expenses")
      assert_nil service.call, text
      assert service.clarification.present?, text
    end
    assert_nil calculate("2 kids, i make 1400", field: "primary_income", components: [ { source: "i make 1400", amount: "1400" } ])
  end

  test "a due-on date misread never becomes an extra bill" do
    text = "rent 1200 due on nov 20"
    parts = [ { source: "rent 1200", amount: "1200" }, { source: "nov 20", amount: "20" } ]
    service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text, components: parts), field: "fixed_expenses")
    assert_nil service.call
    assert service.clarification.present?
  end

  test "a word range misread never becomes two bills" do
    text = "rent 1200 to 1300"
    parts = [ { source: "rent 1200", amount: "1200" }, { source: "to 1300", amount: "1300" } ]
    service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text, components: parts), field: "fixed_expenses")
    assert_nil service.call
    assert service.clarification.present?
  end

  test "an explicitly stated whole total never appends to prior parts" do
    text = "the whole monthly total is 1450"
    service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text), prior: prior, field: "fixed_expenses")
    result = service.call
    assert result.nil? || result[:value] == "1450.0", result.inspect
    assert service.clarification.present? if result.nil?
  end

  test "a named balance in summary mode asks instead of losing name and balance" do
    text = "visa balance is 3000 min 60"
    reading = parsed(text, field: "debt_payment", components: [], setup_answer: { field: "debt", value: "60" })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "debt_payment" } ] }, debt_tracking: { mode: "summary" }, active_debts: [],
      conversation: { active_thread: {}, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("debt_payment") } ] }
    }).call
    assert result.clarification?, result.to_h.inspect
    assert_includes result.clarification, "3,000"
    assert_includes result.clarification, "Visa"
    refute result.actionable?
  end

  test "one partial named debt updates and ambiguous partial names ask which" do
    text = "just the visa, min is 60"
    reading = parsed(text, field: "debt_payment", components: [], setup_answer: { field: "debt", value: "60" })
    context = { participant_reading: reading, setup_status: { complete: true, missing_fields: [] }, debt_tracking: { mode: "individual" },
      active_debts: [ { id: 7, label: "BOQ Visa" } ], conversation: { active_thread: {}, recent_messages: [] } }
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: context).call
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    assert_equal "BOQ Visa", result.action[:debt_name]
    context[:active_debts] << { id: 8, label: "Chase Visa" }
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: context).call
    assert result.clarification?
    assert_includes result.clarification, "BOQ Visa"
    assert_includes result.clarification, "Chase Visa"
  end
  test "a named balance and minimum remain one individual debt" do
    text = "visa balance is 3000 min 60"
    reading = parsed(text, field: "debt_payment", setup_answer: { field: "debt", value: "60" })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "debt_payment" } ] },
      debt_tracking: { mode: "individual" }, active_debts: [],
      conversation: { active_thread: {}, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("debt_payment") } ] }
    }).call
    assert_equal "create_debt", result.action[:type]
    assert_equal "Visa", result.action[:debt_name]
    assert_equal "3000", result.action[:amount]
    assert_equal "60", result.action[:minimum_payment]
  end

  test "named balance and minimum work after setup is complete without a question slot" do
    text = "visa balance is 3000 min 60"
    reading = HouseholdFinance::ParticipantMessageReader.new(message: text).send(:validate,
      { "care" => "none", "facts" => [], "question" => false, "correction" => false, "setup_answer" => { "field" => "none", "value" => "" }, "spending_preferences" => [] })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: true, missing_fields: [] }, debt_tracking: { mode: "individual" },
      active_debts: [ { id: 7, label: "BOQ Visa" } ], conversation: { active_thread: {}, recent_messages: [] }
    }).call
    assert_equal "update_debt", result&.action&.dig(:type)
    assert_equal "3000", result.action[:amount]
    assert_equal "60", result.action[:minimum_payment]
  end

  test "a casual stated no debt creates a true zero minimum" do
    text = "we dont owe anybody thank god"
    reading = parsed(text, field: "debt_payment", components: [])
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "debt_payment" } ] }, debt_tracking: { mode: "individual" },
      conversation: { active_thread: {}, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("debt_payment") } ] }
    }).call
    assert result.actionable?, result.to_h.inspect
    assert_equal "0", result.action[:minimum_payment]
  end

  test "pausing after the final skip retires every earlier setup question" do
    guide = HouseholdFinance::MiaSetupGuide
    messages = guide::NEXT_QUESTIONS.keys.map { |field| { role: "assistant", content: guide.question_message(field) } }
    messages << { role: "assistant", content: "Setup is paused. Still unknown: income. Say resume setup or choose Enter my numbers." }
    guide::NEXT_QUESTIONS.each_key do |field|
      refute guide.server_question_asked?(field, active_thread: {}, recent_messages: messages), field
    end
  end

  test "unequal twice monthly pay asks for the actual total without calling it weekly" do
    text = "paid 1400 twice a month but one is smaller"
    reading = parsed(text, field: "primary_income", components: [], setup_answer: { field: "income", value: "1400" })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "primary_income" } ] },
      conversation: { active_thread: {}, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("primary_income") } ] }
    }).call
    assert result.clarification?
    refute_match(/weekly/i, result.clarification)
    assert_includes result.clarification, "different"
  end
end
