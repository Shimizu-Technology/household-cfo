require "test_helper"

class HouseholdFinanceMiaIntentContextBuilderTest < ActiveSupport::TestCase
  test "builds bounded intent context from the selected month, transcript, and pending reviews" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "intent-context@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Intent Context Household")
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    category = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    annual_plan = manager.plan_data
    transcript = [
      { id: 1, role: "user", content: "What is our largest category?", created_at: "2026-07-01T00:00:00Z" },
      { id: 2, role: "assistant", content: "Fixed essentials is the largest.", created_at: "2026-07-01T00:00:01Z" }
    ]

    context = HouseholdFinance::MiaIntentContextBuilder.new(
      household,
      annual_plan: annual_plan,
      conversation_context: { active_topic: { type: "budget_report", subject: "Fixed essentials" }, rolling_summary: "Older readiness plan" },
      transcript: transcript,
      selected_month: 7
    ).call

    assert_equal "Jul 2026", context.dig(:selected_period, :label)
    assert_equal transcript, context.dig(:conversation, :recent_messages)
    assert_equal "Older readiness plan", context.dig(:conversation, :older_summary)
    category_context = context.fetch(:budget_categories).find { |row| row.fetch(:id) == category.id }
    assert_equal "Fixed essentials", category_context.fetch(:name)
    assert_equal 4_000, category_context.dig(:selected_month, :planned)
    assert_includes context.fetch(:supported_budget_actions), "set_allocation"
    refute context.to_json.include?("s3_key")
  end
end
