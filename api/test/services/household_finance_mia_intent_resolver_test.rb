require "test_helper"

class HouseholdFinanceMiaIntentResolverTest < ActiveSupport::TestCase
  test "resolves a contextual confirmation into a structured supervised budget action" do
    payloads = []
    resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "Yeah, please do that",
      context: intent_context,
      api_key: "test-key",
      transport: lambda do |payload|
        payloads << payload
        resolution_json(
          intent: "budget_action",
          continuation: true,
          resolved_message: "Set Fixed essentials to $3,000 for July 2026",
          topic: { type: "budget_edit", title: "July Fixed essentials edit", subject: "Fixed essentials" },
          action: default_action.merge(
            type: "set_allocation",
            category_id: 42,
            category_name: "Fixed essentials",
            amount: "3000.00",
            months: [ 7 ],
            year: 2026
          )
        )
      end
    )

    result = resolver.call

    assert result.actionable?
    assert result.continuation
    assert_equal "budget_action", result.intent
    assert_equal "set_allocation", result.action.fetch(:type)
    assert_equal 42, result.action.fetch(:category_id)
    assert_equal [ 7 ], result.action.fetch(:months)
    assert_equal "Set Fixed essentials to $3,000 for July 2026", result.resolved_message

    payload = payloads.first
    assert_equal "json_schema", payload.dig(:response_format, :type)
    assert_equal true, payload.dig(:provider, :require_parameters)
    request = payload.fetch(:messages).last.fetch(:content)
    assert_includes request, "Yeah, please do that"
    assert_includes request, "For July can you lower that down to 3000?"
    assert_includes request, "Fixed essentials"
  end

  test "rejects model invented category references and asks for clarification" do
    resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "Lower that to $3,000",
      context: intent_context,
      api_key: "test-key",
      transport: lambda do |_payload|
        resolution_json(
          intent: "budget_action",
          continuation: true,
          resolved_message: "Set Imaginary Bills to $3,000 for July 2026",
          topic: { type: "budget_edit", title: "July category edit", subject: "Imaginary Bills" },
          action: default_action.merge(
            type: "set_allocation",
            category_id: 999,
            category_name: "Imaginary Bills",
            amount: "3000.00",
            months: [ 7 ],
            year: 2026
          )
        )
      end
    )

    result = resolver.call

    assert result.clarification?
    refute result.actionable?
    assert_equal "none", result.action.fetch(:type)
    assert_includes result.clarification, "could not safely match"
  end

  test "returns nil when the provider response is invalid so deterministic fallback can run" do
    resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "Tell me about my budget",
      context: intent_context,
      api_key: "test-key",
      transport: ->(_payload) { "not-json" }
    )

    assert_nil resolver.call
  end

  private

  def intent_context
    {
      selected_period: { year: 2026, month: 7, label: "Jul 2026" },
      conversation: {
        active_thread: { type: "budget_edit", subject: "Fixed essentials" },
        recent_messages: [
          { role: "user", content: "For July can you lower that down to 3000?" },
          { role: "assistant", content: "I can prepare that budget review." }
        ]
      },
      budget_categories: [
        { id: 42, name: "Fixed essentials", stack_key: "non_discretionary" },
        { id: 43, name: "Rent", stack_key: "non_discretionary" }
      ],
      archived_categories: [],
      pending_budget_reviews: [],
      pending_transaction_reviews: []
    }
  end

  def resolution_json(intent:, continuation:, resolved_message:, topic:, action:, confidence: 0.98, needs_clarification: false, clarification: "")
    {
      intent: intent,
      confidence: confidence,
      continuation: continuation,
      resolved_message: resolved_message,
      needs_clarification: needs_clarification,
      clarification: clarification,
      topic: topic,
      action: action
    }.to_json
  end

  def default_action
    {
      type: "none",
      category_id: 0,
      category_name: "",
      target_category_id: 0,
      target_category_name: "",
      new_name: "",
      stack_key: "",
      amount: "",
      months: [],
      year: 0,
      draft_id: 0
    }
  end
end
