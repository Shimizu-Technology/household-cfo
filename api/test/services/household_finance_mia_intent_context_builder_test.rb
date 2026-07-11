require "test_helper"

class HouseholdFinanceMiaIntentContextBuilderTest < ActiveSupport::TestCase
  test "builds bounded intent context from the selected month, transcript, and pending reviews" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "intent-context@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Intent Context Household")
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    category = manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)
    annual_plan = manager.plan_data
    draft = household.transaction_drafts.create!(
      occurred_on: Date.new(2025, 12, 31),
      merchant: "Prior-year Cafe",
      total_amount_cents: 12_34,
      budget_category: category,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "Prior-year pending review"
    )
    draft.transaction_draft_splits.create!(budget_category: category, category_name: category.name, stack_key: category.stack_key, amount_cents: 12_34)
    transcript = [
      { id: 1, role: "user", content: "What is our largest category?", created_at: "2026-07-01T00:00:00Z" },
      { id: 2, role: "assistant", content: "Fixed essentials is the largest.", created_at: "2026-07-01T00:00:01Z" }
    ]

    context = HouseholdFinance::MiaIntentContextBuilder.new(
      household,
      annual_plan: annual_plan,
      conversation_context: { active_topic: { schema_version: 2, type: "budget_report", title: "Budget report", subject: "Fixed essentials" }, rolling_summary: "Older readiness plan" },
      transcript: transcript,
      selected_month: 7
    ).call

    assert_nil context[:selected_period]
    assert_equal "Jul 2026", context.dig(:budget_view_period, :label)
    assert_equal Date.current.iso8601, context.dig(:calendar, :today)
    assert_includes context.dig(:calendar, :relative_date_rule), "not the budget view period"
    assert_equal transcript, context.dig(:conversation, :recent_messages)
    assert_equal "Older readiness plan", context.dig(:conversation, :older_summary)
    category_context = context.fetch(:budget_categories).find { |row| row.fetch(:id) == category.id }
    assert_equal "Fixed essentials", category_context.fetch(:name)
    assert_equal 4_000, category_context.dig(:selected_month, :planned)
    assert_includes context.fetch(:supported_budget_actions), "set_allocation"
    assert_includes context.fetch(:supported_transaction_draft_actions), "update_transaction_draft"
    assert_includes context.fetch(:supported_transaction_draft_actions), "ignore_transaction_drafts"
    assert_includes context.fetch(:transaction_draft_editable_fields), "occurred_on"
    pending_transaction = context.fetch(:pending_transaction_reviews).sole
    assert_equal draft.id, pending_transaction.fetch(:id)
    assert_equal "2025-12-31", pending_transaction.fetch(:occurred_on)
    assert_equal "Prior-year Cafe", pending_transaction.fetch(:merchant)
    refute context.to_json.include?("s3_key")
  end

  test "does not let unvalidated legacy topic summaries override recent raw turns" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "legacy-intent-context@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Legacy Intent Context Household")
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    manager.create_category!(name: "Fixed essentials", stack_key: "non_discretionary", monthly_amount: 4_000)

    context = HouseholdFinance::MiaIntentContextBuilder.new(
      household,
      annual_plan: manager.plan_data,
      conversation_context: {
        active_topic: { type: "readiness_plan", title: "Readiness plan", subject: "runway" },
        open_topics: [ { type: "budget_report", title: "Budget report", subject: "budget report" } ],
        rolling_summary: "The old active topic says readiness."
      },
      transcript: [ { role: "user", content: "Lower Fixed essentials to $3,000 for July." } ],
      selected_month: 7
    ).call

    assert_nil context.dig(:conversation, :active_thread)
    assert_empty context.dig(:conversation, :open_threads)
    assert_nil context.dig(:conversation, :older_summary)
    assert_includes context.dig(:conversation, :recent_messages).first.fetch(:content), "Fixed essentials"
  end

  test "falls back to a canonical selected-period label when month metadata is incomplete" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "partial-intent-context@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Partial Intent Context Household")

    context = HouseholdFinance::MiaIntentContextBuilder.new(
      household,
      annual_plan: { year: 2026, months: [], rows: [], archived_categories: [], pending_mia_action_drafts: [] },
      conversation_context: {},
      transcript: [],
      selected_month: 8
    ).call

    assert_equal({ year: 2026, month: 8, label: "Aug 2026" }, context.fetch(:budget_view_period))
  end
end
