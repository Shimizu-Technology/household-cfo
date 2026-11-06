require "test_helper"

class MiaSetupFlowTest < ActiveSupport::TestCase
  def resolve(text, field: "debt_payment", data: {}, complete: false, active_debts: [])
    payload = { care: "none", facts: [], question: false, correction: false, setup_answer: { field: "none", value: "" }, spending_preferences: [] }.merge(data)
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: text, setup_field: field).send(:validate, payload.deep_stringify_keys)
    HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: complete, missing_fields: HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.drop(HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.index(field)).map { |key| { key: key } } },
      active_debts: active_debts, debt_tracking: { mode: "individual" },
      conversation: { recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message(field) } ], active_thread: {} }
    }).call
  end

  test "a known named debt uses the reader fact even with different minimum punctuation" do
    result = resolve("visa min=60", active_debts: [ { id: 7, label: "Visa", debt_type: "other" } ],
      data: { setup_answer: { field: "debt", value: "60" }, facts: [ { kind: "bill", amount: "60", item: "visa", merchant: "", day: "" } ] })
    assert result.actionable?, result.to_h.inspect
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    refute result.action.key?(:debt_type)
  end

  test "asking to total actual quoted paychecks produces review instead of another monthly question" do
    text = "we get 2 paychecks of 1400, can you add that for our monthly income"
    result = resolve(text, field: "primary_income", data: { question: true, facts: [ { kind: "income", amount: "1400", item: "paychecks", merchant: "", day: "" } ],
      setup_details: { field: "primary_income", cadence: "monthly_count", count: "2", partial: false, components: [ { source: "2 paychecks of 1400", amount: "1400" } ] } })
    assert result&.actionable?, result.to_h.inspect
    assert_equal "2800.0", result.action.dig(:setup_updates, :primary_income)
  end

  test "a named minimum updates its existing individual debt instead of asking for a household total" do
    result = resolve("just the visa, min is 60", active_debts: [ { id: 7, label: "Visa", minimum_payment_known: false } ],
      data: { setup_answer: { field: "debt", value: "60" } })
    assert result.actionable?, result.to_h.inspect
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    assert_equal "60", result.action[:minimum_payment]
    refute result.action.key?(:amount)
  end

  test "calculated totals preserve explicit spending group choices" do
    preferences = [ { family: "groceries", group: "fixed", evidence: "groceries go in fixed" } ]
    result = resolve("rent 1200 and groceries 300; groceries go in fixed", field: "fixed_expenses", data: {
      spending_preferences: preferences, setup_details: { field: "fixed_expenses", cadence: "monthly", count: "", partial: true,
        components: [ { source: "rent 1200", amount: "1200" }, { source: "groceries 300", amount: "300" } ] } })
    assert result.actionable?, result.to_h.inspect
    assert_equal preferences.map(&:stringify_keys), result.action[:spending_preferences]
  end

  test "a plain saved goal correction remains reviewable" do
    result = resolve("change my goal to cover school fees", field: "primary_goal", complete: true,
      data: { correction: true, setup_answer: { field: "goal", value: "cover school fees" } })
    assert result&.actionable?, result.to_h.inspect
    assert_equal "cover school fees", result.action.dig(:setup_updates, :primary_goal)
  end

  test "correcting fixed essentials while an income review is pending does not retarget the income" do
    message = "actually fixed essentials is 1450"
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: message, pending_field: "primary_income").send(:validate,
      { "care" => "none", "facts" => [], "question" => false, "correction" => true, "setup_answer" => { "field" => "fixed", "value" => "1450" }, "spending_preferences" => [] })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: true, missing_fields: [ { key: "debt_payment" } ] },
      conversation: { active_thread: { status: "pending_review", action: { type: "schedule_income_change", amount: "3500", income_source_id: 1 } }, recent_messages: [] }
    }).call
    assert_equal "update_household_setup", result.action[:type]
    assert_equal "1450", result.action.dig(:setup_updates, :fixed_expenses)
  end

  test "a question mentioning a bill is answered before asking for a setup total" do
    result = resolve("does rent 1200 count as fixed essentials", field: "primary_income", data: {
      question: true, facts: [ { kind: "bill", amount: "1200", item: "rent", merchant: "", day: "" } ] })
    refute result&.actionable?
    refute_match(/one monthly total/i, result&.clarification.to_s)
    assert_includes result&.clarification.to_s, "regular must-pay"
  end

  test "a monthly named card payment remains reviewable after optional debt stops gating setup" do
    result = resolve("$325 a month on the Mastercard", complete: true)
    assert result.actionable?, result.to_h.inspect
    assert_equal "325", result.action[:minimum_payment]
    refute result.action.key?(:amount)
    grocery = resolve("$325 a month on groceries", complete: true)
    refute_equal "create_debt", grocery&.action.to_h[:type]
  end

  test "an old pending setup card does not restart questioning after the form completes" do
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: "thanks").send(:validate,
      { "care" => "none", "facts" => [], "question" => false, "correction" => false, "setup_answer" => { "field" => "none", "value" => "" }, "spending_preferences" => [] })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "thanks", api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: true, missing_fields: [ { key: "debt_payment" } ] },
      conversation: { active_thread: { status: "pending_review", action: { type: "update_household_setup", setup_updates: { household_name: "Old name" } } },
        recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("household_name") } ] }
    }).call
    refute result&.clarification?, result.to_h.inspect
  end

  test "the reader can recognize a new deferral without a wording regex" do
    result = resolve("could we park this one for now", field: "primary_income", data: { defer_setup: true })
    assert result.clarification?
    assert_includes result.clarification, "fixed essentials"
    assert_equal "none", result.action[:type]
  end

  test "two named debt minimums are calculated only into a pending total" do
    text = "visa min is 95 and the car is 310"
    result = resolve(text, data: { setup_details: { field: "debt_payment", cadence: "monthly", count: "", partial: true,
      components: [ { source: "visa min is 95", amount: "95" }, { source: "the car is 310", amount: "310" } ] } })
    assert result.actionable?, result.to_h.inspect
    assert_equal "405.0", result.action[:minimum_payment]
    assert_equal "unknown", result.action[:amount]
    assert_includes result.action.dig(:setup_calculation, :description), "Visa $95 + car $310 = $405"
  end

  test "an everyday spending question is answered and resumes without becoming a value" do
    result = resolve("what do you mean by everyday spending", field: "flexible_spend", data: { question: true })
    assert result.clarification?
    assert_includes result.clarification, "groceries"
    assert_includes result.clarification, "what monthly amount would you like to review"
    assert_equal "none", result.action[:type]
  end

  test "no debt payments produces a minimum-only review even after setup completes" do
    result = resolve("no debt payments", complete: true)
    assert result.actionable?, result.to_h.inspect
    assert_equal "0", result.action[:minimum_payment]
    assert_equal "unknown", result.action[:amount]
  end

  test "a single named minimum needs no total clarification" do
    result = resolve("just the visa, min is 60")
    assert result.actionable?, result.to_h.inspect
    assert_equal "60", result.action[:minimum_payment]
  end

  test "a saved named field can be corrected with a review" do
    result = resolve("actually my monthly income is 4200", field: "fixed_expenses", data: { correction: true, setup_answer: { field: "income", value: "4200" } })
    assert result.actionable?, result.to_h.inspect
    assert_equal "4200", result.action.dig(:setup_updates, :primary_income)
  end

  test "skipping asks another question without inventing zero" do
    result = resolve("idk yet", field: "primary_income")
    assert result.clarification?
    assert_includes result.clarification, "Enter my numbers"
    assert_includes result.clarification, "fixed essentials"
    assert_equal "none", result.action[:type]
  end
end
