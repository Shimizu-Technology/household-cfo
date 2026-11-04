require "test_helper"

class SavingsReviewCategoriesTest < ActiveSupport::TestCase
  setup do
    @categories = SavingsChallenge::Daily::ReviewCategories::DEFAULTS.map.with_index do |(stack, name), index|
      BudgetCategory.new(id: index + 1, name: name, stack_key: stack)
    end
  end

  test "general utility housing and insurance merchants get bills hints" do
    [ "Island Electric", "Utility Services", "Mobile Telecom", "Pacific Insurance", "Island Power", "Water Authority", "Internet Services", "Phone Service", "Rent", "Mortgage" ].each do |merchant|
      assert_equal 1, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant), merchant
    end
  end

  test "general food department and discount merchants get everyday hints" do
    [ "Island Restaurant", "Sunset Grill", "Village Cafe", "1776 Coffee", "Family Pizza", "Fresh Juice", "Burger King", "Wendy's", "KFC", "Taco Bell", "Subway", "Department Store", "Discount Store", "Walmart", "Target", "Macy's" ].each do |merchant|
      assert_equal 2, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant), merchant
    end
  end

  test "transfers payments fees and refunds never get merchant hints" do
    [ "GPA payment", "Water transfer", "Ross refund", "Internet fee" ].each do |merchant|
      assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant), merchant
    end
    %w[transfer debt_payment fee refund income unknown adjustment].each do |event_type|
      assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Island Power", event_type: event_type), event_type
    end
  end
end
