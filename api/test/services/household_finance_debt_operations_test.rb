require "test_helper"

class HouseholdFinanceDebtOperationsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "debt_ops_#{SecureRandom.hex(4)}", email: "debt-ops-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "create preserves unknown values and replays the exact invocation" do
    input = { label: "Medical bill", debt_type: "medical", balance: nil, minimum_payment: nil, interest_rate_percent: nil, source_type: "manual_ui" }
    first = @runner.run(operation_key: "debt.record.create", input: input, idempotency_key: "create-medical")
    replay = @runner.run(operation_key: "debt.record.create", input: input, idempotency_key: "create-medical")

    assert replay.replayed?
    assert_equal first.execution.id, replay.execution.id
    assert_not first.subject.balance_known?
    assert_not first.subject.minimum_payment_known?
    assert_nil first.subject.interest_rate_percent
    assert_equal 1, @household.debts.count
    expected = first.execution.predicted_after_snapshot.fetch("debt")
    assert_equal expected, first.after_snapshot.fetch("debt").slice(*expected.keys)
  end

  test "changed payload with the same idempotency key conflicts" do
    @runner.run(operation_key: "debt.record.create", input: { label: "Visa", debt_type: "credit_card", balance: 100 }, idempotency_key: "same-key")

    assert_raises(HouseholdFinance::Operations::Runner::IdempotencyConflict) do
      @runner.run(operation_key: "debt.record.create", input: { label: "Visa", debt_type: "credit_card", balance: 200 }, idempotency_key: "same-key")
    end
    assert_equal 10_000, @household.debts.find_by!(label: "Visa").balance_cents
  end

  test "archive and restore preserve identity history and block an active duplicate" do
    debt = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    archived = @runner.run(operation_key: "debt.record.archive", input: { debt_id: debt.id }, idempotency_key: "archive")
    assert_not archived.subject.active?
    assert archived.subject.archived_at.present?

    replacement = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 80_000, minimum_payment_cents: 4_000)
    error = assert_raises(ArgumentError) do
      @runner.run(operation_key: "debt.record.restore", input: { debt_id: debt.id }, idempotency_key: "restore-conflict")
    end
    assert_match(/active debt already uses/i, error.message)
    assert_not debt.reload.active?
    assert replacement.active?
  end

  test "a prepared archive records the approval time instead of the proposal time" do
    debt = @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    operation = HouseholdFinance::Operations::Debt::RecordArchive.new(@household)
    proposed_at = Time.zone.parse("2026-10-01 09:00:00")
    applied_at = proposed_at + 2.days
    prepared = travel_to(proposed_at) { operation.prepare(debt_id: debt.id) }

    result = travel_to(applied_at) do
      @runner.run_prepared(
        prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint,
        idempotency_key: "delayed-archive", source: "mia"
      )
    end

    assert_not prepared.normalized_input.key?("archived_at")
    assert_equal applied_at, result.subject.archived_at
    assert_equal applied_at.iso8601, result.after_snapshot.dig("debt", "archived_at")
  end

  test "prepared Mia debt update fails stale and rolls back" do
    debt = @household.debts.create!(label: "Auto", debt_type: "auto_loan", balance_cents: 500_000, minimum_payment_cents: 25_000)
    operation = HouseholdFinance::Operations::Debt::RecordUpdate.new(@household)
    prepared = operation.prepare(debt_id: debt.id, balance: 4_500)
    debt.update!(balance_cents: 475_000)

    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
      @runner.run_prepared(prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint, idempotency_key: "stale-mia", source: "mia")
    end
    assert_equal 475_000, debt.reload.balance_cents
    assert_empty @household.household_operation_executions.where(idempotency_key: "stale-mia")
  end

  test "locked membership recheck rejects a removed writer" do
    @household.household_memberships.find_by!(user: @user).destroy!

    error = assert_raises(HouseholdFinance::Operations::Runner::InvalidPreparedOperation) do
      @runner.run(operation_key: "debt.record.create", input: { label: "Visa", debt_type: "credit_card" }, idempotency_key: "removed")
    end
    assert_match(/no longer have permission/i, error.message)
    assert_empty @household.debts
  end

  test "canonical portfolio never adds summary and individual sources" do
    @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)
    @runner.run(
      operation_key: "debt.tracking_mode.update",
      input: { mode: "summary", summary_balance: 9_000, summary_minimum_payment: 400 },
      idempotency_key: "summary"
    )
    summary = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal 900_000, summary.total_balance_cents
    assert_equal 40_000, summary.monthly_minimum_cents

    @runner.run(operation_key: "debt.tracking_mode.update", input: { mode: "individual" }, idempotency_key: "individual")
    individual = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal 100_000, individual.total_balance_cents
    assert_equal 5_000, individual.monthly_minimum_cents
  end

  test "an empty individual portfolio remains unconfirmed instead of becoming a known zero" do
    portfolio = HouseholdFinance::DebtPortfolio.new(@household)
    snapshot = HouseholdFinance::SnapshotBuilder.new(@household).call

    assert_equal "individual", portfolio.mode
    assert_equal 0, portfolio.total_balance_cents
    assert_equal 0, portfolio.monthly_minimum_cents
    assert_not portfolio.balance_known?
    assert_not portfolio.minimum_payment_known?
    assert_not snapshot.fetch(:debt_balance_known)
    assert_not snapshot.fetch(:debt_minimums_known)
  end

  test "a known zero summary explicitly records that the household has no debt" do
    @runner.run(
      operation_key: "debt.tracking_mode.update",
      input: { mode: "summary", summary_balance: 0, summary_minimum_payment: 0 },
      idempotency_key: "confirmed-no-debt"
    )

    portfolio = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert portfolio.balance_known?
    assert portfolio.minimum_payment_known?
    assert_equal 0, portfolio.total_balance_cents
    assert_equal 0, portfolio.monthly_minimum_cents
  end
end
