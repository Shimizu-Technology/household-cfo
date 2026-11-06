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

  test "groceries and fuel need a choice instead of a broad fixed default" do
    [ "Payless", "Payless Supermarket", "Cost-U-Less", "Shell", "Mobil", "Groceries", "Fuel", "Gasoline" ].each do |merchant|
      assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant), merchant
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
  test "merchant service fees are never bank fee hints" do
    [ "DOORDASH SERVICE FEE", "Delivery service charge", "Amazon monthly fee" ].each do |merchant|
      %w[purchase fee].each do |event_type|
        assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant, event_type: event_type), merchant
      end
    end
    [ "Bank service fee", "Bank of Guam service charge", "Monthly maintenance fee", "Overdraft fee", "Monthly service fee" ].each do |merchant|
      assert_equal 1, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, merchant, event_type: "fee"), merchant
    end
  end

  test "explicit bank fees can be reviewed in the broad bills category" do
    assert_equal 1, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Monthly service fee", event_type: "fee")
    assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Unrecognized fee", event_type: "fee")
  end

  test "one active household category in each stack gets hints regardless of its name" do
    @categories[0].name = "Fixed essentials"
    @categories[1].name = "Flexible spending"
    assert_equal 1, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "GPA")
    assert_equal 2, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Ross")
    @categories << BudgetCategory.new(id: 3, name: "Dining out", stack_key: "discretionary")
    assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Ross")
    @categories.last.active = false
    assert_equal 2, SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Ross")
    @categories[1].name = "Everyday spending"
    @categories.last.active = true
    assert_nil SavingsChallenge::Daily::ReviewCategories.suggestion(@categories, "Ross"), "default labels must not bypass a detailed budget"
  end
end
