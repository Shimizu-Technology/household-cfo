require "test_helper"

class HouseholdFinancePilotProgressBatchBuilderTest < ActiveSupport::TestCase
  test "batch results match individual progress semantics without exposing private details" do
    invited_user = create_user("batch-invited@example.com")
    invited_user.update!(invited_at: 1.day.ago)

    started_user = create_user("batch-started@example.com")
    started_household = HouseholdFinance::WorkspaceResolver.new(started_user).household
    started_household.household_audit_events.create!(
      user: started_user,
      actor_type: "user",
      event_type: "workspace.setup_saved",
      metadata: { setup_complete: false },
      occurred_at: 1.hour.ago
    )

    complete_user = create_user("batch-complete@example.com")
    complete_user.update!(last_sign_in_at: 2.hours.ago)
    complete_household = HouseholdFinance::WorkspaceResolver.new(complete_user).household
    HouseholdFinance::SetupUpdater.new(complete_household, complete_setup_values).call
    complete_household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: "Private merchant",
      total_amount_cents: 12_345,
      source_type: "manual_ui",
      status: "pending"
    )

    users = [ invited_user, started_user, complete_user ]
    expected = users.to_h { |user| [ user.id, HouseholdFinance::PilotProgressBuilder.new(user).call ] }
    actual = HouseholdFinance::PilotProgressBatchBuilder.new(users).call

    assert_equal expected, actual
    assert_equal "not_started", actual.fetch(invited_user.id).fetch(:setup_status)
    assert_equal "started", actual.fetch(started_user.id).fetch(:setup_status)
    assert_equal "complete", actual.fetch(complete_user.id).fetch(:setup_status)
    assert actual.fetch(complete_user.id).fetch(:has_pending_review_work)
    actual.each_value do |progress|
      assert_equal %i[has_pending_review_work invited last_safe_activity_at setup_complete setup_status signed_in], progress.keys.sort
    end
  end

  test "batch uses each users earliest household membership" do
    user = create_user("batch-first-household@example.com")
    first_household = Household.create!(name: "Incomplete first household", created_by_user: user)
    second_household = Household.create!(name: "Complete second household", primary_goal: "Build a plan", created_by_user: user)
    first_membership = first_household.household_memberships.create!(user: user, role: "owner")
    second_membership = second_household.household_memberships.create!(user: user, role: "partner")
    first_membership.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    second_membership.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)
    HouseholdFinance::SetupUpdater.new(second_household, complete_setup_values).call

    progress = HouseholdFinance::PilotProgressBatchBuilder.new([ user ]).call.fetch(user.id)

    assert_equal "not_started", progress.fetch(:setup_status)
    assert_equal false, progress.fetch(:setup_complete)
  end

  test "query count stays bounded at the pilot ceiling" do
    one_user = create_users_with_workspaces(1, prefix: "batch-small")
    pilot_cohort = create_users_with_workspaces(21, prefix: "batch-pilot")

    one_user_queries = count_sql_queries do
      HouseholdFinance::PilotProgressBatchBuilder.new(one_user).call
    end
    pilot_queries = count_sql_queries do
      result = HouseholdFinance::PilotProgressBatchBuilder.new(pilot_cohort).call
      assert_equal 21, result.size
    end

    assert_operator pilot_queries, :<=, one_user_queries + 1
    assert_operator pilot_queries, :<=, 30
  end

  private

  def create_user(email)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def create_users_with_workspaces(count, prefix:)
    count.times.map do |index|
      user = create_user("#{prefix}-#{index}@example.com")
      HouseholdFinance::WorkspaceResolver.new(user).household
      user
    end
  end

  def count_sql_queries
    count = 0
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)

      count += 1
    end

    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    end
    count
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
