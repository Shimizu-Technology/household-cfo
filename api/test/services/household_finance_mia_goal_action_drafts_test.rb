require "test_helper"

class HouseholdFinanceMiaGoalActionDraftsTest < ActiveSupport::TestCase
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

  setup do
    @user = User.create!(clerk_id: "mia_goal_#{SecureRandom.hex(4)}", email: "mia-goal-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
  end

  test "Mia prepares a typed goal create and applies it only after review" do
    before = HouseholdFinance::SnapshotBuilder.new(@household).call
    result = build(type: "create_goal", goal_name: "Family trip", goal_type: "travel", target_amount: "5000", current_amount: "unknown", target_on: "2027-06-01")
    assert_equal "goal_plan", result.proposal.draft_type
    assert_empty @household.goals.tracked

    draft = persist(result.proposal)
    item = draft.mia_action_items.sole
    assert_equal "goal.record.create", item.operation_key
    assert_equal false, item.prepared_operation.dig("normalized_input", "current_amount_known")
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
    assert_equal "Not entered", review.find { |field| field.fetch(:label) == "Current progress" }.fetch(:after)

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    goal = @household.goals.tracked.find_by!(label: "Family trip")
    assert_equal "mia", goal.source_type
    assert_equal 500_000, goal.target_amount_cents
    assert_not goal.current_amount_known?
    after = HouseholdFinance::SnapshotBuilder.new(@household.reload).call
    assert_equal before.slice(:monthly_income_cents, :total_outflow_cents, :liquid_assets_cents, :runway_months, :safe_to_spend_cents),
      after.slice(:monthly_income_cents, :total_outflow_cents, :liquid_assets_cents, :runway_months, :safe_to_spend_cents)
  end

  test "Mia review distinguishes unknown progress from known zero" do
    goal = @household.goals.create!(label: "Tuition", goal_type: "education", record_kind: "tracked")
    draft = persist(build(type: "update_goal", goal_id: goal.id, goal_name: goal.label, current_amount: "0").proposal)
    field = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields).find { |item| item.fetch(:label) == "Current progress" }
    assert_equal [ "Not entered", "$0.00" ], field.values_at(:before, :after)
  end

  test "a full Mia action preserves a saved target date unless clear is explicit" do
    goal = @household.goals.create!(
      label: "Family trip", goal_type: "travel", target_amount_cents: 5_000_00,
      target_amount_known: true, target_on: Date.new(2027, 6, 1)
    )

    update = build(DEFAULT_ACTION.merge(type: "update_goal", goal_id: goal.id, goal_name: goal.label, current_amount: "750"))
    update_payload = update.proposal.items.sole.payload
    assert_not_includes update_payload.keys, :target_on
    update_draft = persist(update.proposal)
    applied = HouseholdFinance::MiaActionDraftApplier.new(update_draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal Date.new(2027, 6, 1), goal.reload.target_on

    clear = build(DEFAULT_ACTION.merge(type: "update_goal", goal_id: goal.id, goal_name: goal.label, target_on: "unknown"))
    assert_nil clear.proposal.items.sole.payload.fetch(:target_on)
  end

  test "Mia archive uses a locked prepared operation and preserves history" do
    goal = @household.goals.create!(label: "Home deposit", goal_type: "home", target_amount_cents: 20_000_00, current_amount_cents: 3_000_00)
    draft = persist(build(type: "archive_goal", goal_id: goal.id, goal_name: goal.label).proposal)
    goal.update!(current_amount_cents: 3_100_00)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert_not result.success?
    assert_match(/changed since/, result.errors.to_sentence)
    assert goal.reload.active?
  end

  private

  def build(command)
    HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: @manager, raw_input: "goal command", command: command).call
  end

  def persist(proposal)
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    proposal.create_draft!(source_chat_message: session.chat_messages.create!(role: "user", content: "Update my goal"), assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change"))
  end
end
