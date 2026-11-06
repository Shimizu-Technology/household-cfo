require "test_helper"

class MiaSetupFlowTest < ActiveSupport::TestCase
  def resolve(text, field: "debt_payment", data: {}, complete: false)
    parsed = HouseholdFinance::ParticipantMessageReader.call(message: text, setup_field: field, transport: ->(_) {
      { care: "none", facts: [], question: false, correction: false, setup_answer: { field: "none", value: "" }, spending_preferences: [] }.merge(data).to_json
    })
    HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: complete, missing_fields: HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.drop(HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.index(field)).map { |key| { key: key } } },
      active_debts: [], debt_tracking: { mode: "individual" },
      conversation: { recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message(field) } ], active_thread: {} }
    }).call
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
    assert_includes result.action.dig(:setup_calculation, :description), "$95 + $310 = $405"
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
