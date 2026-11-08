require "test_helper"

class MiaSetupSingleAnswerBoundaryTest < ActiveSupport::TestCase
  test "ordinary single answers leave arithmetic to the existing answer path" do
    [ "i bring home like 3900 a month after taxes", "oh wait no its more like 4100" ].each do |message|
      service = HouseholdFinance::MiaSetupCalculation.new(message: message, reading: nil, field: "primary_income")
      assert_nil service.call
      assert_nil service.clarification, message
    end
  end

  test "pending edits use quoted reader intent independent of preambles" do
    prior = HouseholdFinance::MiaSetupCalculation.new(message: "rent 1500 and internet 80 and phones 90", reading: nil, field: "fixed_expenses").call
    [ [ "oh forgot car insurance 118", "add", "car insurance", "118", "1788.0" ],
      [ "wait the phones is only 75", "replace", "phones", "75", "1773.0" ],
      [ "take out the internet, its included in rent now", "remove", "internet", "", "1693.0" ] ].each do |message, operation, item, amount, expected|
      reading = HouseholdFinance::ParticipantMessageReader.call(message: message, pending_field: "fixed_expenses", transport: ->(_) {
        { care: "none", question: false, setup_details: { field: "fixed_expenses", edit: { operation: operation, item: item, amount: amount, source: message } } }.to_json
      })
      prior = HouseholdFinance::MiaSetupCalculation.new(message: message, reading: reading, field: "fixed_expenses", prior: prior).call
      assert_equal expected, prior&.dig(:value), message
    end
  end

  test "ambiguous pending edit keeps the old list" do
    prior = HouseholdFinance::MiaSetupCalculation.new(message: "rent 1500 and phones 90", reading: nil, field: "fixed_expenses").call
    message = "actually that ones only 75"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, pending_field: "fixed_expenses", transport: ->(_) {
      { care: "none", setup_details: { field: "fixed_expenses", edit: { operation: "replace", item: "", amount: "75", source: message } } }.to_json
    })
    service = HouseholdFinance::MiaSetupCalculation.new(message: message, reading: reading, field: "fixed_expenses", prior: prior)
    assert_nil service.call
    assert_includes service.clarification, "Which part"
    assert_equal "1590.0", prior[:value]
  end

  test "reader questions cannot become text setup answers" do
    message = "wait im confused whats the household cfo thing mean"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, pending_field: "household_name", transport: ->(_) {
      { care: "none", question: true, correction: true, setup_answer: { field: "name", value: message } }.to_json
    })
    assert_nil reading.answer_field
  end
end
