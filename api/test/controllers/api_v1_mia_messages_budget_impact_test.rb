require "test_helper"

class ApiV1MiaMessagesBudgetImpactTest < ActiveSupport::TestCase
  test "draft message explains the category result without claiming actuals changed" do
    household = create_household
    category = household.budget_categories.create!(name: "Gas", stack_key: "discretionary", active: true, sort_order: 1)
    draft = household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 13),
      merchant: "Gas station",
      total_amount_cents: 20_000,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $200 on gas",
      budget_category: category
    )
    plan = {
      year: 2026,
      rows: [
        {
          id: category.id,
          name: "Gas",
          months: Array.new(12) { |index| { planned: index == 6 ? 50 : 0, actual: 0, remaining: index == 6 ? 50 : 0 } }
        }
      ],
      pending_transaction_drafts: [
        { id: draft.id, occurred_on: "2026-07-13", amount: 200, amount_cents: 20_000, category_id: category.id, category_name: "Gas", splits: [] }
      ]
    }

    message = Api::V1::MiaMessagesController.new.send(:drafted_transaction_message, draft, plan)

    assert_includes message, "If approved, July's Gas category would be $150 over its $50 plan."
    assert_includes message, "Month-to-date actuals will not change until you approve it."
  end

  private

  def create_household
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    Household.create!(
      created_by_user: user,
      name: "Test household",
      primary_goal: "Build a clear monthly money rhythm."
    ).tap do |household|
      household.household_memberships.create!(user: user, role: "owner")
    end
  end
end
