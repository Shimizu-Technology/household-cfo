require "test_helper"

class ParticipantMessageReaderTest < ActiveSupport::TestCase
  def object(facts: [], care: "none", field: "none", value: "", correction: false, preferences: [])
    { care: care, facts: facts, question: false, setup_answer: { field: field, value: value }, correction: correction, spending_preferences: preferences }
  end

  def fact(kind, amount, day: "today", merchant: "", item: "")
    { kind: kind, amount: amount, merchant: merchant, item: item, day: day }
  end

  def read(text, data, **options)
    HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_payload) { JSON.generate(data) }, **options)
  end

  test "structured facts keep savings spending and different days independent" do
    text = "cant believe i saved 20 today and 10 yesterday, spent 18 at shell today"
    result = read(text, object(facts: [ fact("set_aside", "20"), fact("set_aside", "10", day: "yesterday"), fact("purchase", "18", merchant: "shell") ]))
    assert result.available
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    intake = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    intake.call
    assert_equal [ 2000, 1000 ], intake.intakes.filter_map { |input| input[:amount_cents] }
    assert_equal [ Date.current.iso8601, Date.current.yesterday.iso8601 ], intake.intakes.first(2).pluck(:effective_on)
    assert_equal 1800, intake.intakes.last.dig(:purchases, 0, :amount_cents)
    assert_equal "shell", intake.intakes.last.dig(:purchases, 0, :merchant)
    assert intake.intakes.all? { |input| input[:counted] == false && input[:approval_state] == "unreviewed_input" }
  end

  test "care keeps every reported amount and ordinary idioms do not become care" do
    text = "i lost my job but i still saved $20 today"
    reading = read(text, object(care: "hardship", facts: [ fact("set_aside", "$20") ]))
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: reading)
    parser.call
    assert_equal 2000, parser.intakes.sole[:amount_cents]
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: reading) do
      assert_equal :hardship, HouseholdFinance::ParticipantCare.kind(text)
    end
    [ "my husband is dead set on a new truck", "i fired up the grill", "i lost my work phone", "i lost a bet at work", "my mom dead tired so i cooked" ].each do |message|
      assert_nil HouseholdFinance::ParticipantCare.kind(message), message
    end
  end

  test "malformed invented partial date and unquoted amounts fail closed" do
    [ "200", "2", "2026", "$20", "twenty" ].each do |amount|
      result = read("saved 20 today on 2026-11-06", object(facts: [ fact("set_aside", amount) ]))
      refute result.available, amount
      assert_empty result.facts
    end
    [ {}, object.merge(extra: true), object.merge(question: "false"), object(facts: [ fact("transfer", "20") ]), object.merge(facts: "20") ].each do |data|
      refute read("saved 20 today", data).available
    end
    refute read("20 today", object(facts: [ fact("set_aside", "20", merchant: "Invented") ])).available
  end

  test "setup values are quoted typed scoped and never invented" do
    reading = read("sorry i meant 4500", object(field: "income", value: "4500", correction: true), setup_field: "fixed_expenses", pending_field: "primary_income")
    assert reading.available
    assert_equal "primary_income", reading.answer_field
    refute read("sorry i meant 4500", object(field: "income", value: "4500", correction: true), setup_field: "primary_income").available
    refute read("cruz", object(field: "name", value: "cruz family"), setup_field: "household_name").available
    refute read("rent 1400 power 200", object(field: "fixed", value: "1600"), setup_field: "fixed_expenses").available
  end

  test "outage accepts only clear anchored input and never guesses junk names or goals" do
    reader = HouseholdFinance::ParticipantMessageReader
    [ "idk", "lol", "asdf", "help", "hello", "not sure", "rent is 1400", "whats a good goal", "i dont have a goal", "ya", "k" ].each do |text|
      %w[household_name primary_goal].each do |field|
        result = reader.call(message: text, setup_field: field, api_key: "")
        assert_nil result.answer_field, text
        assert_empty result.facts
      end
    end
    assert_equal "$20", reader.call(message: "$20 set aside today", api_key: "").facts.sole["amount"]
    assert_equal "4500", reader.call(message: "4500", setup_field: "primary_income", api_key: "").setup_answer["value"]
    assert_empty reader.call(message: "cant believe i saved $40 today", api_key: "").facts
    assert_includes reader::OFF_REPLY, "try again"
  end

  test "provider failure and denial follow the same outage contract without retries" do
    count = 0
    result = HouseholdFinance::ParticipantMessageReader.call(message: "saved 20 today", transport: ->(_payload) { count += 1; raise Net::ReadTimeout })
    refute result.available
    assert_equal 1, count
    with_mia_provider_capacity_rejected do |sites|
      result = read("saved 20 today", object)
      refute result.available
      assert_equal [ "participant_message_reader" ], sites
    end
  end

  test "preferences retain the reviewed participant choice and evidence" do
    text = "$2000 including groceries"
    preferences = [ { family: "groceries", group: "fixed", evidence: "including groceries" } ]
    result = read(text, object(field: "fixed", value: "$2000", preferences: preferences), setup_field: "fixed_expenses")
    assert result.available
    assert_equal "fixed", result.spending_preferences.sole["group"]
    refute read(text, object(preferences: [ { family: "groceries", group: "fixed", evidence: "groceries go in bills" } ])).available
  end
end
