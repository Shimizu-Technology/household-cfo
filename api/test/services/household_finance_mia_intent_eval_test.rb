require "test_helper"
require "yaml"

class HouseholdFinanceMiaIntentEvalTest < ActiveSupport::TestCase
  CASE_PATH = Rails.root.join("test/evals/mia_intent_cases.yml")

  test "multi-turn intent fixtures preserve references and supervised action boundaries" do
    cases = Array(YAML.safe_load_file(CASE_PATH).fetch("cases"))

    cases.each do |eval_case|
      context = base_context.merge(
        conversation: {
          active_thread: { type: "budget_edit", title: "July Fixed essentials edit", subject: "Fixed essentials" },
          older_summary: "An older readiness plan exists, but the latest thread is the July budget edit.",
          recent_messages: Array(eval_case["recent_messages"])
        },
        pending_budget_reviews: Array(eval_case["pending_budget_reviews"]),
        pending_transaction_reviews: Array(eval_case["pending_transaction_reviews"])
      )
      resolver = HouseholdFinance::MiaIntentResolver.new(
        user_message: eval_case.fetch("prompt"),
        context: context,
        api_key: "test-key",
        transport: ->(_payload) { eval_case.fetch("model_resolution").to_json }
      )

      result = resolver.call

      assert result, eval_case.fetch("id")
      assert_equal eval_case.fetch("expected_intent"), result.intent, eval_case.fetch("id")
      assert_equal eval_case.fetch("expected_action"), result.action.fetch(:type), eval_case.fetch("id")
      assert_equal eval_case["expected_category_id"], result.action.fetch(:category_id), eval_case.fetch("id") if eval_case.key?("expected_category_id")
      assert_equal eval_case["expected_months"], result.action.fetch(:months), eval_case.fetch("id") if eval_case.key?("expected_months")
      assert_equal eval_case["expected_amount"], result.action.fetch(:amount), eval_case.fetch("id") if eval_case.key?("expected_amount")
      assert_equal eval_case["expected_draft_id"], result.action.fetch(:draft_id), eval_case.fetch("id") if eval_case.key?("expected_draft_id")
      assert_equal eval_case["expected_occurred_on"], result.action.fetch(:occurred_on), eval_case.fetch("id") if eval_case.key?("expected_occurred_on")
      assert_equal eval_case["expected_merchant"], result.action.fetch(:merchant), eval_case.fetch("id") if eval_case.key?("expected_merchant")
      assert_equal eval_case["expected_all_pending"], result.action.fetch(:all_pending), eval_case.fetch("id") if eval_case.key?("expected_all_pending")
      assert_equal eval_case["expected_clarification"], result.clarification?, eval_case.fetch("id") if eval_case.key?("expected_clarification")
    end
  end

  private

  def base_context
    {
      budget_view_period: { year: 2026, month: 7, label: "Jul 2026" },
      budget_categories: [
        { id: 42, name: "Fixed essentials", stack_key: "non_discretionary", selected_month: { planned: 4_000, actual: 0, remaining: 4_000 } },
        { id: 43, name: "Rent", stack_key: "non_discretionary", selected_month: { planned: 1_800, actual: 0, remaining: 1_800 } }
      ],
      archived_categories: [],
      pending_budget_reviews: [],
      pending_transaction_reviews: []
    }
  end
end
