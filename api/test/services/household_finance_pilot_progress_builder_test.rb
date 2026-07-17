require "test_helper"

class HouseholdFinancePilotProgressBuilderTest < ActiveSupport::TestCase
  test "default workspace remains not started until the participant saves or adds meaningful records" do
    user = create_user("not-started@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    progress = HouseholdFinance::PilotProgressBuilder.new(user, household: household).call

    assert_equal "not_started", progress.fetch(:setup_status)
    assert_equal false, progress.fetch(:setup_complete)
    assert_equal false, progress.fetch(:has_pending_review_work)
    assert_not progress.key?(:household_name)
    assert_not progress.key?(:profile_completeness)
    assert_not progress.key?(:readiness_label)
  end

  test "explicit setup save marks setup started without exposing financial content" do
    user = create_user("started@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.household_audit_events.create!(
      user: user,
      actor_type: "user",
      event_type: "workspace.setup_saved",
      metadata: { setup_complete: false },
      occurred_at: Time.current
    )

    progress = HouseholdFinance::PilotProgressBuilder.new(user, household: household).call

    assert_equal "started", progress.fetch(:setup_status)
    assert_equal false, progress.fetch(:setup_complete)
  end

  test "complete setup pending review and last activity are returned as safe operational signals" do
    user = create_user("complete@example.com")
    user.update!(last_sign_in_at: 2.hours.ago)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::SetupUpdater.new(household, complete_setup_values).call
    draft = household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: "Private merchant",
      total_amount_cents: 12_345,
      source_type: "manual_ui",
      status: "pending"
    )

    progress = HouseholdFinance::PilotProgressBuilder.new(user, household: household).call

    assert_equal "complete", progress.fetch(:setup_status)
    assert_equal true, progress.fetch(:setup_complete)
    assert_equal true, progress.fetch(:has_pending_review_work)
    assert_operator progress.fetch(:last_safe_activity_at), :>=, draft.updated_at
    assert_equal %i[has_pending_review_work invited last_safe_activity_at setup_complete setup_status signed_in], progress.keys.sort
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def complete_setup_values
    {
      household_name: "Pilot Household",
      primary_goal: "Build a stable plan",
      primary_income: 5_000,
      business_income: 0,
      fixed_expenses: 2_500,
      flexible_spend: 600,
      expected_sinking_fund: 200,
      unexpected_sinking_fund: 150,
      emergency_fund: 8_000,
      other_assets: 0,
      credit_card_debt: 1_000,
      debt_payment: 100,
      target_runway_months: 6
    }
  end
end
