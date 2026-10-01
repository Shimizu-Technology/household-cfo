require "test_helper"

class HouseholdFinanceSetupStatusTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "setup-status-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Setup status household")
  end

  test "does not expose readiness when expense essentials were never confirmed" do
    @household.update!(
      primary_goal: "Build a six-month emergency fund",
      confirmed_setup_fields: %w[household_name primary_goal primary_income]
    )
    @household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 620_000, cadence: "monthly")
    @household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_200_000)
    @household.debts.create!(label: "Credit card", debt_type: "credit_card", balance_cents: 310_000, minimum_payment_cents: 17_500)
    @household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    status = HouseholdFinance::SetupStatus.new(@household)
    workspace = HouseholdFinance::DataPresenter.new(@household, user: @user).app_data

    refute status.complete?
    assert_equal %w[fixed_expenses flexible_spend], status.missing_field_keys
    refute workspace.dig(:workspace, :setup_complete)
    refute workspace.dig(:dashboard, :summary, :readiness_available)
    assert_equal 0, workspace.dig(:dashboard, :summary, :next_safe_to_spend_amount)
    assert_includes workspace.dig(:dashboard, :summary, :readiness_label), "Setup incomplete"
  end

  test "an explicitly confirmed zero flexible amount completes the five-field baseline" do
    HouseholdFinance::SetupUpdater.new(
      @household,
      household_name: "Zero-flex household",
      primary_goal: "Protect the baseline",
      primary_income: 4_500,
      fixed_expenses: 3_200,
      flexible_spend: 0
    ).call

    status = HouseholdFinance::SetupStatus.new(@household.reload)

    assert status.complete?
    assert_includes status.confirmed_field_keys, "flexible_spend"
    assert_equal 0, HouseholdFinance::DataPresenter.new(@household).setup_values.fetch(:flexible_spend)
  end

  test "optional asset setup keeps blanks unknown and refuses to overwrite detailed accounts" do
    HouseholdFinance::SetupUpdater.new(@household, emergency_fund: "").call
    emergency = @household.accounts.find_by!(label: "Emergency fund", account_type: "emergency_fund")
    assert_not emergency.balance_known?
    refute_includes @household.reload.confirmed_setup_fields, "emergency_fund"

    @household.accounts.create!(label: "Brokerage", account_type: "other", balance_cents: 25_000, balance_known: true)
    error = assert_raises(ArgumentError) { HouseholdFinance::SetupUpdater.new(@household, other_assets: 500).call }
    assert_includes error.message, "tracked by detailed accounts"
    assert_equal 25_000, @household.accounts.find_by!(label: "Brokerage").balance_cents
  end

  test "resubmitting the displayed asset total preserves aggregate and detailed accounts" do
    aggregate = @household.accounts.create!(label: "Other assets", account_type: "other", balance_cents: 10_000, balance_known: true, source_type: "setup")
    detailed = @household.accounts.create!(label: "Brokerage", account_type: "other", balance_cents: 20_000, balance_known: true)

    assert_no_changes(-> { @household.accounts.order(:id).pluck(:id, :balance_cents, :active) }) do
      HouseholdFinance::SetupUpdater.new(@household, other_assets: 300).call
    end
    assert_equal 10_000, aggregate.reload.balance_cents
    assert_equal 20_000, detailed.reload.balance_cents
  end

  test "rejects blank required values instead of silently confirming them" do
    error = assert_raises(ArgumentError) do
      HouseholdFinance::SetupUpdater.new(@household, primary_income: " ").call
    end
    assert_includes error.message, "enter 0"

    HouseholdFinance::SetupUpdater.new(@household, primary_goal: " ").call
    assert_empty @household.reload.confirmed_setup_fields
  end

  test "a required text field cleared outside setup cannot remain confirmed" do
    HouseholdFinance::SetupUpdater.new(
      @household,
      household_name: "Cleared goal household",
      primary_goal: "Build stability",
      primary_income: 4_500,
      fixed_expenses: 3_200,
      flexible_spend: 0
    ).call
    @household.update_column(:primary_goal, nil)

    status = HouseholdFinance::SetupStatus.new(@household.reload)

    refute status.complete?
    assert_includes status.missing_field_keys, "primary_goal"
  end

  test "saving the same setup twice keeps confirmed fields unique" do
    attributes = {
      household_name: "Idempotent household",
      primary_goal: "Build stability",
      primary_income: 4_500,
      fixed_expenses: 3_200,
      flexible_spend: 0
    }

    2.times { HouseholdFinance::SetupUpdater.new(@household, attributes).call }

    confirmed = @household.reload.confirmed_setup_fields
    assert_equal confirmed.uniq, confirmed
    assert_equal HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s).sort, confirmed.sort
  end
end
