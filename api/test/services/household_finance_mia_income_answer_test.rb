require "test_helper"

class HouseholdFinanceMiaIncomeAnswerTest < ActiveSupport::TestCase
  test "recognizes questions about what came in" do
    [ "How much came in last month?", "how much money came in in October?", "How much did we earn in September?",
      "how much did i make last month", "How much have we brought in this year?", "How much do we get paid a month?" ].each do |message|
      assert HouseholdFinance::MiaIncomeAnswer.question?(message), message
    end
  end

  test "leaves spending, purchases, plan changes and what-ifs to their own answers" do
    [ "How much did I spend last month?", "Can I afford a $1,200 crib?", "How much came in and how much did we spend?",
      "Add $500 to what came in", "How much would come in if I took the second job?", "What's my income this month?",
      "Bought diapers for $45 at Payless today. How much came in this month?", "How much came in vs went out last month?",
      "My salary is now 6,000 a month. How much do we make now?" ].each do |message|
      refute HouseholdFinance::MiaIncomeAnswer.question?(message), message
    end
  end

  test "a plan enough to pay off a card is not the month question" do
    refute HouseholdFinance::MiaMonthAnswer.question?("Is my plan enough to pay off the card by June?")
    assert HouseholdFinance::MiaMonthAnswer.question?("Is our budget enough?")
  end

  test "income topic covers saved-records wording so no reading can turn it into spending" do
    assert HouseholdFinance::MiaIncomeAnswer.topic?("What's my income this month?")
    assert HouseholdFinance::MiaIncomeAnswer.topic?("how much is our salary")
    refute HouseholdFinance::MiaIncomeAnswer.topic?("I got a raise on my income!")
    refute HouseholdFinance::MiaIncomeAnswer.topic?("Can I afford a TV on my salary?")
  end
end
