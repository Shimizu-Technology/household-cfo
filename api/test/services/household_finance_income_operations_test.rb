require "test_helper"

class HouseholdFinanceIncomeOperationsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(clerk_id: "income_ops_#{SecureRandom.hex(8)}", email: "income-ops-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "source create is temporal, audited, and idempotent" do
    input = { label: "Weekend consulting", source_type: "business", amount: 1_200, cadence: "monthly", starts_on: "2026-10-19", year: 2026 }
    first = @runner.run(operation_key: "income.source.create", input: input, idempotency_key: "income-create")
    replay = @runner.run(operation_key: "income.source.create", input: input, idempotency_key: "income-create")

    source = first.subject.reload
    assert_equal source, replay.subject
    assert replay.replayed?
    assert_equal Date.new(2026, 10, 1), source.starts_on
    assert_equal 0, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 9, 30))
    assert_equal 120_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 10, 31))
    assert_equal 1, @household.household_operation_executions.where(idempotency_key: "income-create").count
    assert_equal 1, @household.household_audit_events.where(event_type: "household_operation.executed").count
  end

  test "source archive preserves earlier months and restore is undo only" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
      @runner.run(operation_key: "income.source.archive", input: { source_id: source.id, ends_on: "2026-10-01", year: 2026 }, idempotency_key: "archive")

      refute source.reload.active?
      assert_equal 500_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 9, 30))
      assert_equal 0, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 10, 31))
      september = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
      assert_equal 5_000, september.fetch(:monthly_income).values.fetch(8)

      @runner.run(operation_key: "income.source.restore", input: { source_id: source.id, year: 2026 }, idempotency_key: "restore")
      assert source.reload.active?
    end

    travel_to Date.new(2026, 11, 2) do
      source = @household.income_sources.find_by!(label: "Salary")
      source.update!(active: false, ends_on: Date.new(2026, 10, 1))
      error = assert_raises(ArgumentError) do
        @runner.run(operation_key: "income.source.restore", input: { source_id: source.id, year: 2026 }, idempotency_key: "late-restore")
      end
      assert_includes error.message, "Create a new source"
      refute source.reload.active?
    end
  end

  test "a future end boundary remains current and can accept changes before it ends" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
      @runner.run(operation_key: "income.source.archive", input: { source_id: source.id, ends_on: "2026-12-01", year: 2026 }, idempotency_key: "future-archive")

      refute source.reload.active?
      assert source.effective_on?(Date.current)
      assert_equal 500_000, HouseholdFinance::SnapshotBuilder.new(@household.reload, reference_date: Date.current).call.fetch(:monthly_income_cents)

      scheduled = @runner.run(
        operation_key: "income.schedule.create",
        input: { source_id: source.id, entry_type: "recurring_change", amount: 5_500, cadence: "monthly", effective_on: "2026-11-01", year: 2026 },
        idempotency_key: "future-ended-schedule"
      )
      assert_equal source, scheduled.subject
      assert_equal 550_000, source.income_schedule_entries.sole.amount_cents
      assert_equal 0, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.new(2026, 12, 1))
    end
  end

  test "case insensitive conflicts and retained job transitions fail closed" do
    source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    source.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 350_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1), retained_after_transition: true)

    error = assert_raises(ArgumentError) do
      @runner.run(operation_key: "income.source.update", input: { source_id: source.id, source_type: "business", year: 2026 }, idempotency_key: "retype")
    end
    assert_includes error.message, "Clear continuing transition income"
    assert_equal "job", source.reload.source_type

    @household.income_sources.create!(label: "Consulting", source_type: "business", amount_cents: 100_000, cadence: "monthly")
    assert_raises(ActiveRecord::RecordInvalid) do
      @runner.run(operation_key: "income.source.create", input: { label: "consulting", source_type: "business", amount: 2_000, cadence: "monthly", starts_on: "2026-10-01", year: 2026 }, idempotency_key: "duplicate")
    end
  end

  test "a closed source name can be reused while restore protects an active replacement" do
    travel_to Date.new(2026, 11, 2) do
      archived = @household.income_sources.create!(
        label: "Seasonal work", source_type: "other", amount_cents: 100_000, cadence: "monthly",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 10, 1), active: false
      )
      created = @runner.run(
        operation_key: "income.source.create",
        input: { label: "seasonal WORK", source_type: "other", amount: 1_500, cadence: "monthly", starts_on: "2026-11-01", year: 2026 },
        idempotency_key: "replacement-source"
      ).subject

      assert_equal 2, @household.income_sources.where(source_type: "other").count
      assert created.active?
      refute archived.reload.active?
    end

    travel_to Date.new(2026, 11, 2) do
      ending = @household.income_sources.create!(
        label: "Contract", source_type: "business", amount_cents: 200_000, cadence: "monthly",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 1), active: false
      )
      @household.income_sources.create!(label: "CONTRACT", source_type: "business", amount_cents: 300_000, cadence: "monthly", starts_on: Date.new(2026, 12, 1))

      error = assert_raises(ArgumentError) do
        @runner.run(operation_key: "income.source.restore", input: { source_id: ending.id, year: 2026 }, idempotency_key: "restore-replaced")
      end
      assert_includes error.message, "active income source already uses that name and type"
      refute ending.reload.active?
    end
  end

  test "same-name timelines cannot overlap but can restart at the prior exclusive end month" do
    ended = @household.income_sources.create!(
      label: "Seasonal work", source_type: "other", amount_cents: 100_000, cadence: "monthly",
      starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 10, 1), active: false
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      @runner.run(
        operation_key: "income.source.create",
        input: { label: "seasonal WORK", source_type: "other", amount: 1_500, cadence: "monthly", starts_on: "2026-09-01", year: 2026 },
        idempotency_key: "overlapping-replacement"
      )
    end
    assert_includes error.record.errors.full_messages.to_sentence, "overlaps"

    replacement = @runner.run(
      operation_key: "income.source.create",
      input: { label: "seasonal WORK", source_type: "other", amount: 1_500, cadence: "monthly", starts_on: "2026-10-01", year: 2026 },
      idempotency_key: "boundary-replacement"
    ).subject
    assert_equal ended.ends_on, replacement.starts_on
  end

  test "aggregate setup treats a future-ended source as current" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(
        label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 1), active: false
      )

      HouseholdFinance::SetupUpdater.new(@household, primary_income: 5_500).call

      assert_equal 1, @household.income_sources.where(source_type: "job").count
      refute source.reload.active?
      assert_equal Date.new(2026, 12, 1), source.ends_on
      assert_equal 550_000, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: Date.current)
    end
  end

  test "a future source can be canceled before it starts and restored" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(
        label: "New contract", source_type: "business", amount_cents: 200_000, cadence: "monthly", starts_on: Date.new(2027, 2, 1)
      )

      @runner.run(
        operation_key: "income.source.archive",
        input: { source_id: source.id, ends_on: "2026-10-01", year: 2026 },
        idempotency_key: "cancel-future-source"
      )

      refute source.reload.active?
      assert_equal source.starts_on, source.ends_on
      assert_equal "archived", source.timeline_status(on: Date.current)
      assert_equal 0, HouseholdFinance::IncomeTimeline.recurring_monthly_cents(source, on: source.starts_on)

      @runner.run(
        operation_key: "income.source.restore",
        input: { source_id: source.id, year: 2027 },
        idempotency_key: "restore-future-source"
      )
      assert source.reload.active?
      assert_nil source.ends_on
      assert_equal "future", source.timeline_status(on: Date.current)
    end
  end

  test "moving a source start cannot strand saved changes and entries after an end are inactive" do
    source = @household.income_sources.create!(
      label: "Contract", source_type: "business", amount_cents: 200_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1)
    )
    entry = source.income_schedule_entries.create!(
      entry_type: "recurring_change", amount_cents: 250_000, cadence: "monthly", effective_on: Date.new(2026, 6, 1)
    )

    error = assert_raises(ArgumentError) do
      @runner.run(
        operation_key: "income.source.update",
        input: { source_id: source.id, starts_on: "2026-07-01", year: 2026 },
        idempotency_key: "strand-entry"
      )
    end
    assert_includes error.message, "Move or remove that change first"
    assert_equal Date.new(2026, 1, 1), source.reload.starts_on

    @runner.run(
      operation_key: "income.source.archive",
      input: { source_id: source.id, ends_on: "2026-05-01", year: 2026 },
      idempotency_key: "end-before-entry"
    )
    payload = HouseholdFinance::IncomeSourcePresenter.new(source.reload).as_json
    refute payload.fetch(:schedule_entries).find { |candidate| candidate.fetch(:id) == entry.id }.fetch(:active)
  end

  test "aggregate setup never reopens a closed income history" do
    travel_to Date.new(2026, 11, 2) do
      archived = @household.income_sources.create!(
        label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 10, 1), active: false
      )

      HouseholdFinance::SetupUpdater.new(@household, primary_income: 6_000).call

      refute archived.reload.active?
      assert_equal Date.new(2026, 10, 1), archived.ends_on
      replacement = @household.income_sources.where(active: true, source_type: "job").sole
      assert_equal "Primary income", replacement.label
      assert_equal 600_000, replacement.amount_cents
    end
  end

  test "schedule create update delete share exact stale snapshots" do
    source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    created = @runner.run(operation_key: "income.schedule.create", input: { source_id: source.id, entry_type: "recurring_change", amount: 6_000, cadence: "monthly", effective_on: "2026-10-01", year: 2026 }, idempotency_key: "schedule-create")
    entry = source.income_schedule_entries.sole
    assert_equal source, created.subject
    assert_equal 600_000, entry.amount_cents
    assert_equal [ "IncomeSource", source.id ], created.execution.values_at(:subject_type, :subject_id)

    updated = @runner.run(operation_key: "income.schedule.update", input: { source_id: source.id, entry_id: entry.id, entry_type: "recurring_change", amount: 6_500, cadence: "monthly", effective_on: "2026-11-01", year: 2026 }, idempotency_key: "schedule-update")
    assert_equal source, updated.subject
    assert_equal 650_000, entry.reload.amount_cents
    assert_equal [ "IncomeSource", source.id ], updated.execution.values_at(:subject_type, :subject_id)

    prepared = nil
    @household.with_lock do
      prepared = HouseholdFinance::Operations::Income::ScheduleUpdate.new(@household).prepare(source_id: source.id, entry_id: entry.id, entry_type: "recurring_change", amount: 7_000, cadence: "monthly", effective_on: "2026-12-01", year: 2026)
    end
    entry.update!(amount_cents: 675_000)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
      @runner.run_prepared(prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint, idempotency_key: "stale-schedule")
    end

    deleted = @runner.run(operation_key: "income.schedule.delete", input: { source_id: source.id, entry_id: entry.id, year: 2026 }, idempotency_key: "schedule-delete")
    replay = @runner.run(operation_key: "income.schedule.delete", input: { source_id: source.id, entry_id: entry.id, year: 2026 }, idempotency_key: "schedule-delete")
    assert_equal source, deleted.subject
    assert replay.replayed?
    refute IncomeScheduleEntry.exists?(entry.id)
  end

  test "tampered prepared operation fails before mutation" do
    source = @household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    prepared = nil
    @household.with_lock do
      prepared = HouseholdFinance::Operations::Income::ScheduleCreate.new(@household).prepare(source_id: source.id, entry_type: "one_time", amount: 400, effective_on: "2026-12-01", year: 2026)
    end
    tampered = prepared.as_json.deep_dup
    tampered["normalized_input"]["amount_cents"] = 999_999

    assert_raises(HouseholdFinance::Operations::Runner::InvalidPreparedOperation) do
      @runner.run_prepared(prepared: tampered, prepared_fingerprint: prepared.fingerprint, idempotency_key: "tampered")
    end
    assert_empty source.income_schedule_entries
  end

  test "Mia source creation and legacy schedule commands use registered operations" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    proposal = HouseholdFinance::MiaActionDraftBuilder.new(
      @household, user: @user, annual_budget_manager: manager, raw_input: "Add consulting",
      command: {
        type: "create_income_source", income_source_name: "Consulting", source_type: "business",
        amount: "1200", cadence: "monthly", effective_on: "2026-10-01"
      }
    ).call.proposal
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    user_message = session.chat_messages.create!(role: "user", content: "Add consulting")
    assistant_message = session.chat_messages.create!(role: "assistant", content: "Review this change")
    draft = proposal.create_draft!(source_chat_message: user_message, assistant_chat_message: assistant_message)

    assert_equal "income.source.create", draft.mia_action_items.sole.operation_key
    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert result.success?, result.errors.to_sentence
    assert_equal 120_000, @household.income_sources.find_by!(label: "Consulting").amount_cents
    assert_equal "income.source.create", @household.household_operation_executions.sole.operation_key
  end

  test "Mia can prepare and apply a future source end boundary" do
    travel_to Date.new(2026, 10, 15) do
      source = @household.income_sources.create!(label: "Contract", source_type: "business", amount_cents: 200_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
      manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
      proposal = HouseholdFinance::MiaActionDraftBuilder.new(
        @household, user: @user, annual_budget_manager: manager, raw_input: "End Contract beginning December",
        command: { type: "archive_income_source", income_source_id: source.id, effective_on: "2026-12-01" }
      ).call.proposal
      session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
      draft = proposal.create_draft!(
        source_chat_message: session.chat_messages.create!(role: "user", content: "End Contract beginning December"),
        assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change")
      )

      item = draft.mia_action_items.sole
      assert_equal "income.source.archive", item.operation_key
      assert_equal "2026-12-01", item.prepared_operation.dig("normalized_input", "ends_on")
      review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
      boundary = review.find { |field| field.fetch(:label) == "First $0 month" }
      assert_equal "Ongoing", boundary.fetch(:before)
      assert_equal "$0 beginning December 2026", boundary.fetch(:after)
      result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
      assert result.success?, result.errors.to_sentence
      assert_equal Date.new(2026, 12, 1), source.reload.ends_on
      assert source.effective_on?(Date.new(2026, 11, 30))
      refute source.effective_on?(Date.new(2026, 12, 1))
    end
  end
end
