require "test_helper"

class MiaSetupCompletionTest < ActiveSupport::TestCase
  def reading(text, **details)
    payload = { care: "none", facts: [], question: false, correction: false, setup_answer: { field: "none", value: "" }, spending_preferences: [], setup_details: details }
    HouseholdFinance::ParticipantMessageReader.new(message: text, setup_field: details[:field]).send(:validate, payload.deep_stringify_keys)
  end

  test "a hypothetical paycheck question never becomes a setup calculation" do
    text = "if we get 2 paychecks of 1400, would that help"
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: text, setup_field: "primary_income").send(:validate,
      { care: "none", question: true, facts: [ { kind: "income", amount: "1400", item: "paychecks", merchant: "", day: "" } ], correction: false,
        setup_answer: { field: "none", value: "" }, spending_preferences: [], setup_details: { field: "primary_income", cadence: "monthly_count", count: "2", partial: false, components: [ { source: "2 paychecks of 1400", amount: "1400" } ] } }.deep_stringify_keys)
    assert_empty parsed.facts
    assert_nil HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed).call
  end

  test "bill facts still produce a review when the reader omits optional list details" do
    text = "rent 990 and water 65"
    parsed = HouseholdFinance::ParticipantMessageReader.call(message: text, setup_field: "fixed_expenses", transport: ->(_) {
      { care: "none", question: false, correction: false, setup_answer: { field: "none", value: "" }, spending_preferences: [],
        facts: [ { kind: "bill", item: "rent", amount: "990", merchant: "", day: "" }, { kind: "bill", item: "water", amount: "65", merchant: "", day: "" } ] }.to_json
    })
    result = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed, field: "fixed_expenses").call
    assert_equal "1055.0", result[:value]
    assert_includes result[:description], "$990 + $65 = $1,055"
  end

  test "server adds exact bill spans and preserves a partial list for review" do
    text = "rent 1200 and power 300 so far"
    details = { field: "fixed_expenses", cadence: "monthly", count: "", partial: true,
      components: [ { source: "rent 1200", amount: "1200" }, { source: "power 300", amount: "300" } ] }
    result = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: reading(text, **details)).call
    assert_equal "1500.0", result[:value]
    assert_includes result[:description], "$1,200 + $300 = $1,500"
    assert_includes result[:description], "missing"
  end

  test "quoted paycheck count is multiplied by Ruby only for a stated monthly count" do
    text = "2 paychecks of 1400"
    details = { field: "primary_income", cadence: "monthly_count", count: "2", partial: false,
      components: [ { source: text, amount: "1400" } ] }
    result = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: reading(text, **details)).call
    assert_equal "2800.0", result[:value]
    assert_includes result[:description], "2 × $1,400 = $2,800"
    details[:cadence] = "biweekly"
    assert_nil HouseholdFinance::MiaSetupCalculation.new(message: text, reading: reading(text, **details)).call
  end

  test "negative quoted bill amounts do not become positive totals" do
    [ "rent -1200", "rent -$1200", "rent −$1200" ].each do |text|
      parsed = reading(text, field: "fixed_expenses", cadence: "monthly", count: "", partial: true, components: [ { source: text, amount: "1200" } ])
      assert_nil HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed).call
    end
  end

  test "invented overlapping and malformed amounts cannot enter a calculated review" do
    text = "rent 1200 and power 300"
    [ [ { source: "rent 1200", amount: "1500" } ],
      [ { source: text, amount: "1200" }, { source: "power 300", amount: "300" } ],
      [ { source: "rent 1200", amount: "12" } ] ].each do |components|
      parsed = reading(text, field: "fixed_expenses", cadence: "monthly", count: "", partial: false, components: components)
      assert_nil HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed).call
    end
  end
end
