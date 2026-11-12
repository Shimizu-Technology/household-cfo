require "date"
require "minitest/autorun"
require_relative "../../app/services/household_finance/month_terms"
require_relative "../../app/services/household_finance/mia_month_answer"

# Use Rails' executor lifecycle in the combined suite; keep the small
# standalone Ruby check available when ActiveSupport has not been loaded.
class HouseholdFinanceMiaMonthQuestionTest < (defined?(ActiveSupport::TestCase) ? ActiveSupport::TestCase : Minitest::Test)
  def test_month_overviews_leave_daily_questions_in_the_daily_flow
    [ "how much do i have left this month", "how much is left this month", "How did October look?", "How did Oct 2026 look?", "How did last month look?" ].each do |text|
      assert HouseholdFinance::MiaMonthAnswer.question?(text), text
    end
    [ "How did today look?", "How did yesterday look?", "How did Friday look?" ].each do |text|
      refute HouseholdFinance::MiaMonthAnswer.question?(text), text
    end
  end
end
