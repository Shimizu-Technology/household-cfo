require "test_helper"

class SavingsChallengeGoalAmountTest < ActiveSupport::TestCase
  test "scales a monthly figure over three months to a friendly goal between 100 and 1000 dollars" do
    {
      6_000 => 20_000,    # $180 -> $200
      10_000 => 30_000,   # $300
      2_200 => 10_000,    # $66 is too small: the $100 floor
      40_000 => 100_000,  # $1,200 is too big: the $1,000 ceiling
      21_300 => 60_000,   # $639 -> nearest $100
      7_500 => 25_000     # $225 -> nearest $50
    }.each do |monthly, goal|
      result = SavingsChallenge::GoalAmount.pattern_goal(monthly)
      assert_equal goal, result[:goal_cents], "monthly #{monthly}"
      assert result[:scaled]
      assert_equal monthly * 3, result[:raw_cents]
    end
  end

  test "falls back to the standard 500 dollars when there is no usable monthly figure" do
    [ nil, 0, -500, "", "abc" ].each do |monthly|
      result = SavingsChallenge::GoalAmount.pattern_goal(monthly)
      assert_equal 50_000, result[:goal_cents], monthly.inspect
      assert_not result[:scaled]
    end
  end
end
