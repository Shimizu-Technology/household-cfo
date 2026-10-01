require "test_helper"

class HouseholdFinanceOperationsRunnerTest < ActiveSupport::TestCase
  setup do
    @user = create_user("operations-#{SecureRandom.hex(5)}@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "manual operations persist exact versioned snapshots and replay one success" do
    runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
    first = runner.run(
      operation_key: "budget.category.create",
      input: { name: "Dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
      idempotency_key: "create-dining"
    )
    replay = runner.run(
      operation_key: "budget.category.create",
      input: { name: "Dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
      idempotency_key: "create-dining"
    )

    assert replay.replayed?
    assert_equal first.execution.id, replay.execution.id
    assert_equal first.subject.id, replay.subject.id
    assert_equal 1, @household.budget_categories.where(name: "Dining").count
    assert_equal 1, @household.household_operation_executions.where(idempotency_key: "create-dining").count
    assert_equal 1, @household.household_audit_events.where(event_type: "household_operation.executed").count
    execution = first.execution
    assert_equal "budget.category.create", execution.operation_key
    assert_equal 1, execution.operation_version
    assert_equal @household.id, first.execution.household_id
    assert_equal 2026, execution.normalized_input.fetch("year")
    assert_equal execution.predicted_after_snapshot.dig("allocations").map { |row| row.slice("month", "planned_amount_cents") },
      execution.after_snapshot.fetch("allocations").map { |row| row.slice("month", "planned_amount_cents") }
  end

  test "reusing an idempotency key with different normalized input fails closed" do
    runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
    runner.run(
      operation_key: "budget.category.create",
      input: { name: "Dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
      idempotency_key: "same-key"
    )

    error = assert_raises(HouseholdFinance::Operations::Runner::IdempotencyConflict) do
      runner.run(
        operation_key: "budget.category.create",
        input: { name: "Travel", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
        idempotency_key: "same-key"
      )
    end

    assert_includes error.message, "different household change"
    refute @household.budget_categories.exists?(name: "Travel")
    assert_equal 1, @household.household_operation_executions.count
  end

  test "audit failure rolls back every domain side effect and allows a clean retry" do
    failure = ->(_attributes) { raise ActiveRecord::RecordInvalid.new(HouseholdAuditEvent.new) }
    failing_runner = HouseholdFinance::Operations::Runner.new(@household, user: @user, audit_writer: failure)
    input = { name: "Travel", stack_key: "sinking_expected", monthly_amount: 100, year: 2026 }

    assert_raises(ActiveRecord::RecordInvalid) do
      failing_runner.run(operation_key: "budget.category.create", input: input, idempotency_key: "audit-retry")
    end
    refute @household.budget_categories.exists?(name: "Travel")
    assert_empty @household.household_operation_executions
    assert_empty @household.household_audit_events.where(event_type: "household_operation.executed")

    result = HouseholdFinance::Operations::Runner.new(@household, user: @user).run(
      operation_key: "budget.category.create", input: input, idempotency_key: "audit-retry"
    )
    assert_equal "Travel", result.subject.name
    assert_equal 1, @household.household_operation_executions.count
  end

  test "prepared operations cannot cross households" do
    other_user = create_user("operations-other-#{SecureRandom.hex(5)}@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    prepared = nil
    @household.with_lock do
      prepared = HouseholdFinance::Operations::Budget::CategoryCreate.new(@household).prepare(
        name: "Travel", stack_key: "discretionary", monthly_amount: 100, year: 2026
      )
    end

    error = assert_raises(HouseholdFinance::Operations::Runner::InvalidPreparedOperation) do
      HouseholdFinance::Operations::Runner.new(other_household, user: other_user).run_prepared(
        prepared: prepared.as_json,
        prepared_fingerprint: prepared.fingerprint,
        idempotency_key: "foreign-operation"
      )
    end
    assert_includes error.message, "different household"
    refute other_household.budget_categories.exists?(name: "Travel")
  end

  test "restore snapshots and verifies missing dependent allocations and expense item" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    category = manager.create_category!(name: "Travel", stack_key: "sinking_expected", monthly_amount: 100)
    manager.archive_category!(category)
    category.budget_allocations.order(:id).first.delete
    @household.expense_items.where("LOWER(label) = ?", "travel").delete_all

    result = HouseholdFinance::Operations::Runner.new(@household, user: @user).run(
      operation_key: "budget.category.restore",
      input: { category_id: category.id, year: 2026 },
      idempotency_key: "restore-travel"
    )

    assert result.subject.reload.active?
    assert_equal 12, category.budget_allocations.count
    assert_equal 1, @household.expense_items.where(label: "Travel", active: true).count
    assert_equal 12, result.after_snapshot.fetch("allocations").length
  end

  test "restore repairs only its reviewed category and leaves unrelated category rows untouched" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    restored = manager.create_category!(name: "Travel", stack_key: "sinking_expected", monthly_amount: 100)
    unrelated = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    manager.archive_category!(restored)
    prepared = nil
    @household.with_lock do
      prepared = HouseholdFinance::Operations::Registry.fetch("budget.category.restore").new(@household).prepare(
        category_id: restored.id, year: 2026
      )
    end
    unrelated.budget_allocations.order(:id).first.delete

    HouseholdFinance::Operations::Runner.new(@household, user: @user).run_prepared(
      prepared: prepared.as_json,
      prepared_fingerprint: prepared.fingerprint,
      idempotency_key: "restore-with-unrelated-gap"
    )

    assert restored.reload.active?
    assert_equal 12, restored.budget_allocations.count
    assert_equal 11, unrelated.budget_allocations.count
  end

  test "household destruction removes operation ledger before its required audit" do
    HouseholdFinance::Operations::Runner.new(@household, user: @user).run(
      operation_key: "budget.category.create",
      input: { name: "Dining", stack_key: "discretionary", monthly_amount: 250, year: 2026 },
      idempotency_key: "destroy-household"
    )
    execution_id = @household.household_operation_executions.sole.id
    audit_id = @household.household_audit_events.find_by!(event_type: "household_operation.executed").id

    @household.destroy!

    refute HouseholdOperationExecution.exists?(execution_id)
    refute HouseholdAuditEvent.exists?(audit_id)
  end

  test "manual and Mia allocation paths execute the same operation contract" do
    manual_category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
      .create_category!(name: "Manual groceries", stack_key: "discretionary", monthly_amount: 500)
    manual_allocation = manual_category.budget_allocations.joins(:budget_period)
      .find_by!(budget_periods: { starts_on: Date.new(2026, 8, 1) })
    manual = HouseholdFinance::Operations::Runner.new(@household, user: @user).run(
      operation_key: "budget.allocation.set",
      input: { allocation_id: manual_allocation.id, category_id: manual_category.id, year: 2026, planned_amount: 650 },
      idempotency_key: "manual-allocation"
    )

    mia_category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
      .create_category!(name: "Mia groceries", stack_key: "discretionary", monthly_amount: 500)
    result = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026),
      selected_month: 8,
      raw_input: "Set Mia groceries to $650 for August",
      command: { type: "set_allocation", category_id: mia_category.id, amount: "650", months: [ 8 ], year: 2026 }
    ).call
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    draft = result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "Set Mia groceries to $650 for August"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: result.response)
    )
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call

    assert applied.success?, applied.errors.to_sentence
    mia_execution = @household.household_operation_executions.find_by!(reviewable: draft.mia_action_items.sole)
    assert_equal manual.execution.operation_key, mia_execution.operation_key
    assert_equal manual.execution.operation_version, mia_execution.operation_version
    assert_equal 65_000, manual_allocation.reload.planned_amount_cents
    assert_equal 65_000, mia_category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.new(2026, 8, 1) }).planned_amount_cents
    assert_equal "manual", manual.execution.source
    assert_equal "mia", mia_execution.source
  end

  test "mixed registered and legacy drafts keep both operation and aggregate audit semantics" do
    category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
      .create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    result = HouseholdFinance::MiaActionDraftBuilder.new(
      @household,
      user: @user,
      annual_budget_manager: HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026),
      selected_month: 8,
      raw_input: "Set Groceries to $650 for August",
      command: { type: "set_allocation", category_id: category.id, amount: "650", months: [ 8 ], year: 2026 }
    ).call
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    draft = result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "Set Groceries to $650 for August"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: result.response)
    )
    draft.mia_action_items.create!(
      position: 1, action_type: "update_setup_value", label: "Rename household",
      payload: { key: "household_name", value: "Cruz Household" },
      before_snapshot: { value: @household.name }, after_snapshot: { value: "Cruz Household" }
    )

    assert_difference("HouseholdAuditEvent.count", 2) do
      result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
      assert result.success?, result.errors.to_sentence
    end
    assert_equal "Cruz Household", @household.reload.name
    assert_equal %w[household_operation.executed mia_action_draft.applied],
      @household.household_audit_events.where(event_type: %w[household_operation.executed mia_action_draft.applied]).order(:id).pluck(:event_type)
  end

  test "legacy identity is all null and partial or hidden prepared identities are rejected" do
    draft = create_draft
    legacy = draft.mia_action_items.create!(
      position: 0, action_type: "update_setup_value", label: "Legacy setup",
      payload: { key: "household_name", value: "Cruz Household" },
      before_snapshot: { value: @household.name }, after_snapshot: { value: "Cruz Household" }
    )
    assert_nil legacy.operation_key
    assert_equal({}, legacy.prepared_operation)

    hidden = draft.mia_action_items.build(
      position: 1, action_type: "update_setup_value", label: "Hidden prepared",
      payload: {}, before_snapshot: {}, after_snapshot: {}, prepared_operation: { "operation_key" => "budget.category.create" }
    )
    refute hidden.valid?

    partial = draft.mia_action_items.build(
      position: 2, action_type: "update_setup_value", label: "Partial prepared",
      payload: {}, before_snapshot: {}, after_snapshot: {}, operation_key: "budget.category.create"
    )
    refute partial.valid?
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(8)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def create_draft
    @household.mia_action_drafts.create!(
      requested_by_user: @user, draft_type: "household_setup", status: "pending",
      year: 2026, title: "Mixed review", summary: "Review mixed changes"
    )
  end
end
