require "test_helper"

class BudgetCategoryTest < ActiveSupport::TestCase
  test "stack label falls back safely for unexpected stack keys" do
    category = BudgetCategory.new(stack_key: "future_stack")

    assert_equal "Future stack", category.stack_label
  end
end
