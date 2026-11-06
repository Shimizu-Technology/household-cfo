require "test_helper"

class ParticipantMessageReaderValidationTest < ActiveSupport::TestCase
  def data(**values)
    { care: "none", question: false, correction: false, facts: [], setup_answer: { field: "none", value: "" }, spending_preferences: [] }.merge(values)
  end

  def fact(kind, amount, **values)
    { kind: kind, amount: amount, merchant: "", item: "", day: "" }.merge(values)
  end

  def read(message, value, **options)
    HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_) { value.to_json }, **options)
  end

  test "punctuation commas end money while thousands commas stay inside it" do
    [ [ "put away 20, not much but ok", "20" ], [ "lunch 9, dinner 17, saved 5", "9" ], [ "1,200, give or take", "1,200" ] ].each do |text, amount|
      result = read(text, data(facts: [ fact("set_aside", amount) ]))
      assert result.available, text
      assert_equal amount, result.facts.sole["amount"]
    end
    result = read("2100, including groceries", data(setup_answer: { field: "fixed", value: "2100" }), setup_field: "fixed_expenses")
    assert_equal "2100", result.setup_answer["value"]
    refute read("saved 1,200 today", data(facts: [ fact("set_aside", "1") ])).facts.any?
  end

  test "invalid items never erase care questions or independent valid facts" do
    result = read("my mom died and i bought flowers and saved 20 today", data(care: "grief", question: true,
      facts: [ fact("purchase", "", item: "flowers"), fact("set_aside", "20", day: "today"), fact("purchase", "999") ],
      setup_answer: { field: "income", value: "999" }, spending_preferences: [ { family: "groceries", group: "fixed", evidence: "invented" } ]))
    assert result.available
    assert_equal "grief", result.care
    assert result.question
    assert_equal [ "", "20" ], result.facts.pluck("amount")
    assert_nil result.answer_field
    assert_empty result.spending_preferences
  end

  test "missing amounts and compound setup answers are readable rather than outages" do
    result = read("i bought a few groceries today", data(facts: [ fact("purchase", "", item: "groceries", day: "today") ]))
    assert result.available
    assert_equal "", result.facts.sole["amount"]
    result = read("rent 1200 and power 300", data(facts: [ fact("bill", "1200", item: "rent"), fact("bill", "300", item: "power") ], setup_answer: { field: "fixed", value: "1200 and power 300" }), setup_field: "fixed_expenses")
    assert result.available
    assert_nil result.answer_field
    assert_equal 2, result.facts.length
  end

  test "a hypothetical fact is dropped within its own clause without losing an actual report" do
    result = read("if i put 100 away today would that be enough", data(question: true, facts: [ fact("set_aside", "100", day: "today") ]))
    assert result.available
    assert result.question
    assert_empty result.facts
    result = read("i saved 20 today, how am i doing", data(question: true, facts: [ fact("set_aside", "20", day: "today") ]))
    assert_equal "20", result.facts.sole["amount"]
    result = read("i saved 20. would 100 tomorrow be enough", data(question: true, facts: [ fact("set_aside", "20"), fact("set_aside", "100") ]))
    assert_equal [ "20" ], result.facts.pluck("amount")
    result = read("i saved 20 today because i knew it would help", data(facts: [ fact("set_aside", "20", day: "today") ]))
    assert_equal "20", result.facts.sole["amount"]
  end

  test "day phrases remain verbatim in facts for local calendar resolution" do
    result = read("i saved 40 last friday", data(facts: [ fact("set_aside", "40", day: "last friday") ]))
    assert result.available
    assert_equal "last friday", result.facts.sole["day"]
  end
end
