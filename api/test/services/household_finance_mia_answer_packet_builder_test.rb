require "test_helper"

class HouseholdFinanceMiaAnswerPacketBuilderTest < ActiveSupport::TestCase
  test "builds a compact annual plan packet with string keyed plan data" do
    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
      kind: "budget_question",
      fallback_response: "You have $120 remaining and $30 pending review.",
      write_state: "no_write",
      selected_month: 7,
      annual_plan: {
        "year" => 2026,
        "rows" => [
          { "name" => "Groceries", "stack_key" => "needs", "active" => true },
          { "name" => "Old Category", "stack_key" => "wants", "active" => false }
        ],
        "pending_transaction_drafts" => [ { "id" => 1 } ]
      }
    ).call

    assert_equal "budget_question", packet.fetch(:kind)
    assert_equal 2026, packet.fetch(:selected_year)
    assert_equal 7, packet.fetch(:selected_month)
    assert_equal "active annual plan, confirmed actuals, and pending drafts", packet.fetch(:basis)
    assert_equal 1, packet.dig(:annual_plan_summary, :active_category_count)
    assert_equal 1, packet.dig(:annual_plan_summary, :pending_draft_count)
    assert_equal [ { name: "Groceries", stack_key: "needs" }, { name: "Old Category", stack_key: "wants" } ], packet.dig(:annual_plan_summary, :top_categories)
  end
end
