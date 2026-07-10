require "test_helper"

class HouseholdFinanceMiaAnswerPacketBuilderTest < ActiveSupport::TestCase
  test "builds a spending report packet with the report period label" do
    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
      kind: "spending_report",
      fallback_response: "For July 2026, confirmed spending is $85 against $300 planned.",
      write_state: "no_write",
      spending_report: {
        "period_label" => "July 2026",
        "start_on" => "2026-07-01",
        "end_on" => "2026-07-31",
        "totals" => { "planned" => 300.0, "actual" => 85.0, "pending" => 20.0, "remaining" => 215.0 },
        "categories" => [ { "name" => "Groceries", "planned" => 300.0, "actual" => 85.0, "pending" => 20.0, "remaining" => 215.0 } ],
        "transactions" => [ { "id" => 1, "occurred_on" => "2026-07-05", "merchant" => "Payless", "amount" => 85.0, "categories" => [ "Groceries" ] } ],
        "pending_drafts" => []
      },
      conversation_context: { active_topic: { title: "Old receipt" }, rolling_summary: "McDonald's is pending" }
    ).call

    summary = packet.fetch(:spending_report_summary)
    assert_equal "July 2026", summary.fetch(:period_label)
    assert_equal "2026-07-01", summary.fetch(:start_on)
    assert_equal "2026-07-31", summary.fetch(:end_on)
    assert_equal 85.0, summary.dig(:totals, :actual)
    assert_equal 0, summary.fetch(:pending_draft_count)
    assert_equal 1, summary.fetch(:confirmed_transaction_count)
    assert_equal [ { name: "Groceries", planned: 300.0, actual: 85.0, pending: 20.0, remaining: 215.0 } ], summary.fetch(:top_categories)
    assert_equal [ { occurred_on: "2026-07-05", merchant: "Payless", amount: 85.0, categories: [ "Groceries" ] } ], summary.fetch(:top_transactions)
    refute packet.key?(:conversation_context)
  end

  test "builds a compact annual plan packet with string keyed plan data" do
    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(
      kind: "budget_question",
      fallback_response: "You have $120 remaining and $30 pending review.",
      write_state: "no_write",
      selected_month: 7,
      annual_plan: {
        "year" => 2026,
        "rows" => [
          {
            "name" => "Groceries",
            "stack_key" => "needs",
            "active" => true,
            "months" => Array.new(12) { { "planned" => 300.0, "actual" => 85.0, "remaining" => 215.0 } }
          },
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
    assert_equal [ { name: "Groceries", stack_key: "needs", planned: 300.0, actual: 85.0, remaining: 215.0 } ], packet.dig(:annual_plan_summary, :top_categories)
  end
end
