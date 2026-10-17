require "test_helper"

class HouseholdFinanceTransactionCategorySuggesterTest < ActiveSupport::TestCase
  setup do
    user = User.create!(
      clerk_id: "clerk_category_suggester_#{SecureRandom.hex(4)}",
      email: "category-suggester-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: user, name: "Category Suggestion Household")
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    @dining = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 2)
    @suggester = HouseholdFinance::TransactionCategorySuggester.new(@household)
  end

  test "matches an exact active category even when extraction confidence is low" do
    suggestion = @suggester.suggest(
      merchant: "Tita's Demo Market",
      category_name: "Groceries",
      confidence: BigDecimal("0.35"),
      merchant_fallback: false
    )

    assert suggestion.matched?
    assert_equal @groceries, suggestion.category
    assert_equal "exact_category", suggestion.match_reason
  end

  test "does not let a grocery merchant override a different receipt line" do
    suggestion = @suggester.suggest(
      merchant: "Tita's Demo Market",
      category_name: "Household supplies",
      text: "Laundry detergent and paper towels",
      confidence: BigDecimal("0.65"),
      merchant_fallback: false
    )

    refute suggestion.matched?
    assert_equal "needs_review", suggestion.match_status
    assert_equal "no_strong_match", suggestion.match_reason
  end

  test "uses a confirmed merchant rule only when its category history is unambiguous" do
    @household.merchant_category_rules.create!(merchant_pattern: "penny cafe", budget_category: @dining, confidence: 0.9, source: "user_confirmed", active: true)
    suggestion = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Penny Cafe", confidence: 0.35)

    assert_equal @dining, suggestion.category
    assert_equal "confirmed_merchant_history", suggestion.match_reason

    @household.merchant_category_rules.create!(merchant_pattern: "penny cafe", budget_category: @groceries, confidence: 0.85, source: "user_confirmed", active: true)
    ambiguous = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Penny Cafe", confidence: 0.9)

    refute ambiguous.matched?
    assert_equal "ambiguous_merchant_history", ambiguous.match_reason
  end

  test "keeps the manual Mia category fallback separate from strict document suggestions" do
    strict = @suggester.suggest(merchant: "Unknown Shop", stack_key: "discretionary", confidence: 0.9)
    manual_category = @suggester.call(merchant: "Unknown Shop", stack_key: "discretionary", confidence: 0.9)

    refute strict.matched?
    assert_equal @groceries, manual_category
  end

  test "a ride-share or fuel signal never lands in a non-trip vehicle category" do
    insurance = @household.budget_categories.create!(name: "Car insurance", stack_key: "sinking_expected", sort_order: 3)
    @household.budget_categories.create!(name: "Childcare", stack_key: "non_discretionary", sort_order: 4)
    ride = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Uber", text: "TRANSPORTATION TRANSPORTATION_TAXIS_AND_RIDE_SHARES", confidence: BigDecimal("0.80"))

    refute ride.matched?
    assert_equal "no_strong_match", ride.match_reason

    gas = @household.budget_categories.create!(name: "Gas & fuel", stack_key: "discretionary", sort_order: 5)
    fuel = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Shell", text: "TRANSPORTATION TRANSPORTATION_GAS", confidence: BigDecimal("0.80"))

    assert_equal gas, fuel.category
    refute_equal insurance, fuel.category
  end

  test "a category with both a transport and a non-trip term is not used for fuel" do
    mixed = @household.budget_categories.create!(name: "Transportation insurance", stack_key: "sinking_expected", sort_order: 6)
    fuel = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Shell", text: "TRANSPORTATION TRANSPORTATION_GAS", confidence: BigDecimal("0.80"))

    refute fuel.matched?
    refute_equal mixed, fuel.category

    gas = @household.budget_categories.create!(name: "Gas & fuel", stack_key: "discretionary", sort_order: 7)
    fuel = HouseholdFinance::TransactionCategorySuggester.new(@household).suggest(merchant: "Shell", text: "TRANSPORTATION TRANSPORTATION_GAS", confidence: BigDecimal("0.80"))
    assert_equal gas, fuel.category
  end
end
