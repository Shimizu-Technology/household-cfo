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
end
