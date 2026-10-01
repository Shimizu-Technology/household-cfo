require "test_helper"

class HouseholdFinanceGoalOperationsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "goal_ops_#{SecureRandom.hex(4)}", email: "goal-ops-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "unknown and explicit zero goal amounts stay distinct" do
    unknown = create_goal("Emergency reserve", target_amount: nil, current_amount: nil, key: "unknown")
    zero = create_goal("Paid-off car", goal_type: "debt_payoff", target_amount: 0, current_amount: 0, key: "zero")

    assert_not unknown.target_amount_known?
    assert_not unknown.current_amount_known?
    assert zero.target_amount_known?
    assert zero.current_amount_known?
    assert_equal 0, zero.target_amount_cents
    assert_equal [ unknown.id ], HouseholdFinance::GoalPortfolio.new(@household).as_json.fetch(:unknown_target_goal_ids)
  end

  test "tracked goals do not change cash facts or runway policy" do
    HouseholdFinance::SetupUpdater.new(@household, target_runway_months: 6).call
    before = HouseholdFinance::SnapshotBuilder.new(@household).call

    create_goal("Family trip", goal_type: "travel", target_amount: 5_000, current_amount: 1_000, key: "trip")
    after = HouseholdFinance::SnapshotBuilder.new(@household.reload).call

    assert_equal before.slice(:monthly_income_cents, :total_outflow_cents, :liquid_assets_cents, :total_debt_cents, :runway_months, :safe_to_spend_cents),
      after.slice(:monthly_income_cents, :total_outflow_cents, :liquid_assets_cents, :total_debt_cents, :runway_months, :safe_to_spend_cents)
    assert_equal 6, @household.goals.policy.find_by!(goal_type: "runway").target_months
  end

  test "setup reuses a legacy runway policy even when its label differs" do
    legacy = @household.goals.create!(label: "Runway", goal_type: "runway", target_amount_cents: 20_000_00)

    HouseholdFinance::SetupUpdater.new(@household, target_runway_months: 8).call

    assert_equal legacy.id, @household.goals.policy.find_by!(goal_type: "runway").id
    assert_equal "Runway target", legacy.reload.label
    assert_equal 8, legacy.target_months
    assert legacy.target_amount_known?
  end

  test "archive excludes a goal from active totals and restore blocks a duplicate" do
    goal = create_goal("Vacation", goal_type: "travel", target_amount: 3_000, current_amount: 500, key: "vacation")
    @runner.run(operation_key: "goal.record.archive", input: { goal_id: goal.id }, idempotency_key: "archive")
    assert_equal 0, HouseholdFinance::GoalPortfolio.new(@household.reload).as_json.fetch(:target_total)

    create_goal("vacation", goal_type: "travel", target_amount: 4_000, key: "duplicate")
    error = assert_raises(ArgumentError) do
      @runner.run(operation_key: "goal.record.restore", input: { goal_id: goal.id }, idempotency_key: "restore")
    end
    assert_match(/active goal already uses/i, error.message)
    assert_not goal.reload.active?
  end

  test "prepared goal update rejects a stale record" do
    goal = create_goal("Tuition", goal_type: "education", target_amount: 10_000, key: "tuition")
    prepared = HouseholdFinance::Operations::Goal::RecordUpdate.new(@household).prepare(goal_id: goal.id, current_amount: 2_000)
    goal.update!(label: "College tuition")

    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
      @runner.run_prepared(prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint, idempotency_key: "stale", source: "mia")
    end
    assert_not goal.reload.current_amount_known?
  end

  test "idempotent creation is replayed without a duplicate" do
    first = @runner.run(operation_key: "goal.record.create", input: { label: "Home", goal_type: "home", target_amount: 25_000 }, idempotency_key: "same")
    second = @runner.run(operation_key: "goal.record.create", input: { label: "Home", goal_type: "home", target_amount: 25_000 }, idempotency_key: "same")
    assert_equal first.subject.id, second.subject.id
    assert second.replayed?
    assert_equal 1, @household.goals.tracked.count
  end

  test "raw cents require an explicit known flag" do
    error = assert_raises(ArgumentError) do
      @runner.run(
        operation_key: "goal.record.create",
        input: { label: "College", goal_type: "education", target_amount_cents: 50_000 },
        idempotency_key: "missing-target-known"
      )
    end

    assert_equal "Target amount known flag is required with cents", error.message
    assert_empty @household.goals.tracked
  end

  test "raw cents accept explicit unknown and canonicalize them to zero" do
    goal = @runner.run(
      operation_key: "goal.record.create",
      input: {
        label: "College", goal_type: "education",
        target_amount_cents: 50_000, target_amount_known: false
      },
      idempotency_key: "explicit-target-unknown"
    ).subject

    assert_not goal.target_amount_known?
    assert_equal 0, goal.target_amount_cents
  end

  private

  def create_goal(label, goal_type: "savings", target_amount: nil, current_amount: nil, key:)
    @runner.run(
      operation_key: "goal.record.create",
      input: { label: label, goal_type: goal_type, target_amount: target_amount, current_amount: current_amount },
      idempotency_key: key
    ).subject
  end
end
