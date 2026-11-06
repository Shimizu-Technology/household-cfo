require "date"
require "minitest/autorun"
require_relative "../../app/services/household_finance/month_terms"
require_relative "../../app/services/household_finance/mia_month_answer"

class HouseholdFinanceMiaMonthQuestionTest < Minitest::Test
  def test_month_overviews_leave_daily_questions_in_the_daily_flow
    [ "how much do i have left this month", "how much is left this month", "How did October look?", "How did Oct 2026 look?", "How did last month look?" ].each do |text|
      assert HouseholdFinance::MiaMonthAnswer.question?(text), text
    end
    [ "How did today look?", "How did yesterday look?", "How did Friday look?" ].each do |text|
      refute HouseholdFinance::MiaMonthAnswer.question?(text), text
    end
  end
end
