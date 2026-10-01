require "test_helper"

class HouseholdFinanceMiaGoalIntentResolverTest < ActiveSupport::TestCase
  DEFAULT_ACTION = {
    type: "none", category_id: 0, category_name: "", target_category_id: 0,
    target_category_name: "", new_name: "", stack_key: "", amount: "", months: [],
    year: 0, draft_id: 0, occurred_on: "", merchant: "", all_pending: false,
    splits: [], setup_updates: {}, income_source_id: 0, income_source_name: "",
    income_schedule_entry_id: 0, source_type: "", cadence: "",
    retained_after_transition: false, entry_type: "", effective_on: "",
    schedule_label: "", debt_id: 0, debt_name: "", debt_type: "",
    minimum_payment: "", interest_rate_percent: "", debt_tracking_mode: "",
    account_id: 0, account_name: "", account_type: "", balance_as_of_on: "",
    plaid_account_id: 0, reconcile_decision: "", goal_id: 0, goal_name: "",
    goal_type: "", target_amount: "", current_amount: "", target_on: ""
  }.freeze

  test "resolves a grounded tracked-goal update to an exact active record" do
    result = resolve(
      user_message: "Update Family trip to a $6,000 target and $750 saved",
      context: { active_goals: [ { id: 31, label: "Family trip", goal_type: "travel" } ], archived_goals: [] },
      action: { type: "update_goal", goal_id: 31, goal_name: "Family trip", target_amount: "6000", current_amount: "750" }
    )

    assert result.actionable?
    assert_equal "goal_action", result.intent
    assert_equal 31, result.action.fetch(:goal_id)
    assert_equal "6000", result.action.fetch(:target_amount)
    assert_equal "750", result.action.fetch(:current_amount)
  end

  test "rejects a provider-invented goal amount" do
    result = resolve(
      user_message: "Update Family trip to a $6,000 target",
      context: { active_goals: [ { id: 31, label: "Family trip", goal_type: "travel" } ], archived_goals: [] },
      action: { type: "update_goal", goal_id: 31, goal_name: "Family trip", target_amount: "9000" }
    )

    assert result.clarification?
    assert_equal "none", result.action.fetch(:type)
  end

  test "does not allow a tracked-goal action to target runway policy" do
    result = resolve(
      user_message: "Update my runway target to $6,000",
      context: { active_goals: [], archived_goals: [] },
      action: { type: "update_goal", goal_id: 99, goal_name: "Runway target", target_amount: "6000" }
    )

    assert result.clarification?
    assert_equal "none", result.action.fetch(:type)
  end

  test "rejects a provider-invented target date" do
    result = resolve(
      user_message: "Update Family trip progress to $750",
      context: { active_goals: [ { id: 31, label: "Family trip", goal_type: "travel" } ], archived_goals: [] },
      action: { type: "update_goal", goal_id: 31, goal_name: "Family trip", current_amount: "750", target_on: "2027-06-01" }
    )

    assert result.clarification?
    assert_equal "none", result.action.fetch(:type)
  end

  test "accepts an explicit request to clear a target date" do
    result = resolve(
      user_message: "Clear the target date for Family trip",
      context: { active_goals: [ { id: 31, label: "Family trip", goal_type: "travel" } ], archived_goals: [] },
      action: { type: "update_goal", goal_id: 31, goal_name: "Family trip", target_amount: "unknown", target_on: "unknown" }
    )

    assert result.actionable?
    assert_equal "unknown", result.action.fetch(:target_on)
    assert_equal "", result.action.fetch(:target_amount)
  end

  test "drops an unrequested unknown amount" do
    result = resolve(
      user_message: "Rename Family trip to Guam trip",
      context: { active_goals: [ { id: 31, label: "Family trip", goal_type: "travel" } ], archived_goals: [] },
      action: { type: "update_goal", goal_id: 31, goal_name: "Family trip", new_name: "Guam trip", target_amount: "unknown" }
    )

    assert result.actionable?
    assert_equal "", result.action.fetch(:target_amount)
    assert_equal "Guam trip", result.action.fetch(:new_name)
  end

  test "keeps participant-authored goal amounts through a type clarification" do
    %i[target_amount current_amount].each do |field|
      context = {
        active_goals: [], archived_goals: [],
        conversation: {
          active_thread: {
            schema_version: 2, type: "goal_plan", title: "Add tracked goal", subject: "Family trip",
            status: "needs_clarification", action: { type: "create_goal", goal_name: "Family trip", field => "5000" }
          },
          recent_messages: []
        }
      }

      result = resolve(
        user_message: "It is a travel goal.",
        context: context,
        action: { type: "create_goal", goal_name: "Family trip", goal_type: "travel" },
        continuation: true
      )

      assert result.actionable?, "expected #{field} clarification to remain actionable"
      assert_equal "5000", result.action.fetch(field)
    end
  end

  private

  def resolve(user_message:, context:, action:, continuation: false)
    base_context = {
      budget_categories: [], archived_categories: [], active_debts: [], archived_debts: [],
      active_accounts: [], archived_accounts: [], eligible_plaid_accounts: [],
      active_goals: [], archived_goals: [], pending_budget_reviews: [], pending_transaction_reviews: [],
      conversation: {}, budget_view_period: { year: Date.current.year, month: Date.current.month }
    }.merge(context)
    HouseholdFinance::MiaIntentResolver.new(
      user_message: user_message, context: base_context, api_key: "test-key",
      transport: ->(_payload) do
        {
          intent: "goal_action", confidence: 0.99, continuation: continuation,
          resolved_message: user_message, needs_clarification: false, clarification: "",
          topic: { type: "goal_plan", title: "Tracked goal", subject: action[:goal_name].to_s },
          action: DEFAULT_ACTION.merge(action), read_only_plan: { title: "", items: [] }
        }.to_json
      end
    ).call
  end
end
