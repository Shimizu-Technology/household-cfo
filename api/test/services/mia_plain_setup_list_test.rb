require "test_helper"

class MiaPlainSetupListTest < ActiveSupport::TestCase
  SUMS = {
    "rent 875 and power 190" => 106500,
    "rent 1000, gpa 200, water 50, phone 120" => 137000,
    "so rent is 950, gpa bill like 180 and guam waterworks 45" => 117500,
    "rent 1100, power 260" => 136000,
    "rent is 1200 and water is 55" => 125500,
    "ok rent: 900, power: 125" => 102500,
    "well rent = 850 and internet = 75" => 92500,
    "rent about 1000 and power like 150" => 115000,
    "rent $1,000 and water $50.25" => 105025,
    "rent 1000 a month and power 200 monthly" => 120000,
    "rent 1000/mo, phone 80/mo" => 108000,
    "school fees 120 and bus fare 40" => 16000,
    "rent 0 and power 150" => 15000,
    "insurance bill 65.50 and internet bill 75.25" => 14075,
    "ok lets start over. rent 1000, gpa 200, water 50, phone 120" => 137000,
    "rent 1000 and gpa 200 and water 50 and phone 120 and internet 75 and insurance 90 and parking 25 and trash 20" => 158000
  }.freeze
  ASKS = [
    "rent 1000, we owe 4000 on the truck", "paychecks 1400 and rent 1000", "yearly insurance 1200 and power 200", "truck balances 4000 and rent 1000", "bills 1200, rent 1000, power 200", "fixed essentials 1200 and rent 1000 and power 200",
    "rent -1200 and power 200", "rent -$1200 and power 200", "rent −1200 and power 200", "rent isn't 1200 and power 200", "rent minus 1200 and power 200", "two phone lines at 45 each, rent 1000",
    "rent 1000, power 200, 1200", "rent up to 1200 and power 200", "rent between 1000 and 1200",
    "rent 1000 or maybe 1200", "rent 100 per paycheck and power 200", "rent 100 per day and power 200",
    "insurance 1200 per year and power 200", "insurance 300 quarterly and rent 1000",
    "insurance 200 every other month and rent 1000", "rent back in september 1000 and power 200",
    "two phone lines 45 and rent 1000", "rent since 2024 and power 200", "truck balance 4000 and rent 1000",
    "bought shoes 80 and rent 1000", "rent 1200-1300", "rent half of 1200", "power 20% of that",
    "rent due nov 20", "not the 300 storage", "rent 100 a week", "power was 300 last month",
    "rent 1200 and power is like 20% of that", "rent 1200 and power 300 total 1500",
    "rent 1200 to 1300", "rent 1000 and water 50 deposit", "rent 1000 and power 200 ago",
    "rent 1000 and power 200 and water 50 and phone 120 and internet 75 and insurance 90 and parking 25 and trash 20 and cable 30"
  ].freeze

  def parsed(text, **data)
    HouseholdFinance::ParticipantMessageReader.call(message: text, setup_field: "fixed_expenses", transport: ->(_) {
      { care: "none", question: false, unclear_amount: true, facts: [], setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }.merge(data).to_json
    })
  end

  SUMS.each do |text, cents|
    test "plain Ruby list sums #{text}" do
      # Deliberately no cadence, bill facts or usable setup answer; the reader
      # cannot grant or deny the arithmetic grammar.
      result = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text), field: "fixed_expenses").call
      assert result, text
      assert_equal cents, HouseholdFinance::ParticipantMessageReader.amount_cents(result[:value]), text
    end
  end
  ASKS.each do |text|
    test "nonplain Ruby list asks #{text}" do
      # Even a mistaken reader claiming every quoted number is a monthly bill
      # must never authorize this sum.
      components = text.scan(/\d[\d,]*(?:\.\d+)?/).map { |amount| { source: text, amount: amount } }
      reading = parsed(text, unclear_amount: false, setup_details: { field: "fixed_expenses", cadence: "monthly", count: "", partial: false, components: components })
      service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: reading, field: "fixed_expenses")
      assert_nil service.call, text
      assert_match(/What's the total/, service.clarification.to_s, text)
      refute_match(/can't safely|cannot safely/i, service.clarification.to_s)
    end
  end

  test "a stated whole total cannot become a named bill in the next addition" do
    first = HouseholdFinance::MiaSetupCalculation.new(message: "rent 1000 and power 200", reading: nil, field: "fixed_expenses").call
    whole = HouseholdFinance::MiaSetupCalculation.new(message: "the whole monthly total is 1300", reading: nil, field: "fixed_expenses", prior: first).call
    service = HouseholdFinance::MiaSetupCalculation.new(message: "forgot the water 60", reading: nil, field: "fixed_expenses", prior: whole)
    assert_nil service.call
    assert_includes service.clarification, "total"
  end

  test "a start-over preface with a plain list is not a workspace reset" do
    session = ChatSession.new(active_topic: {})
    refute Mia::FinancialRestartRequest.matches?("ok lets start over. rent 1000, gpa 200, water 50, phone 120", session: session)
    assert Mia::FinancialRestartRequest.matches?("reset everything and start over", session: session)
  end

  test "monthly paycheck invitation accepts differing bare check amounts" do
    text = "1400 and 1250"
    service = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text), field: "primary_income")
    result = service.call
    assert_equal "2650.0", result&.dig(:value)
    assert_includes result[:description], "$1,400 + $1,250 = $2,650"
  end

  test "pending list add replace and remove use Ruby words after a clarification" do
    first = HouseholdFinance::MiaSetupCalculation.new(message: "rent 875 and power 190", reading: parsed("rent 875 and power 190"), field: "fixed_expenses").call
    assert first
    [ [ "forgot the internet 75", "1140.0" ], [ "no wait power is 225", "1175.0" ],
      [ "actually no power bill, its included in the rent now", "950.0" ],
      [ "scratch the internet, we dont pay for that anymore", "875.0" ] ].each do |text, expected|
      first = HouseholdFinance::MiaSetupCalculation.new(message: text, reading: parsed(text), field: "fixed_expenses", prior: first).call
      assert_equal expected, first&.dig(:value), text
    end
  end
end
