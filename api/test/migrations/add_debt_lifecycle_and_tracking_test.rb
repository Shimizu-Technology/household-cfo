require "test_helper"
require Rails.root.join("db/migrate/20261002110000_add_debt_lifecycle_and_tracking").to_s

class AddDebtLifecycleAndTrackingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "debt_migration_#{SecureRandom.hex(8)}",
      email: "debt-migration-#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "rollback stops before mutating schema or archived history" do
    debt = @household.debts.create!(
      label: "Archived Visa", debt_type: "credit_card", balance_cents: 90_000,
      minimum_payment_cents: 4_000, active: false, archived_at: 2.days.ago
    )
    columns_before = ApplicationRecord.connection.columns(:debts).map(&:name)
    indexes_before = ApplicationRecord.connection.indexes(:debts).map(&:name)

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddDebtLifecycleAndTracking.new.migrate(:down)
    end

    assert_includes error.message, "archive history"
    assert_equal columns_before, ApplicationRecord.connection.columns(:debts).map(&:name)
    assert_equal indexes_before, ApplicationRecord.connection.indexes(:debts).map(&:name)
    assert_not Debt.find(debt.id).active?
  end

  test "legacy setup aggregate and detailed cards become one reviewable summary without deleting history" do
    @household.update!(confirmed_setup_fields: %w[credit_card_debt debt_payment])
    aggregate = @household.debts.create!(
      label: "Credit card debt", debt_type: "credit_card", balance_cents: 10_000_00,
      minimum_payment_cents: 300_00, source_type: "manual_ui"
    )
    visa = @household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 4_000_00,
      minimum_payment_cents: 125_00, source_type: "document_import"
    )
    auto = @household.debts.create!(
      label: "Auto loan", debt_type: "auto_loan", balance_cents: 8_000_00,
      minimum_payment_cents: 275_00, source_type: "manual_ui"
    )

    AddDebtLifecycleAndTracking.new.reconcile_legacy_setup_debts!

    assert_not aggregate.reload.active?
    assert aggregate.archived_at.present?
    assert_equal "setup", aggregate.source_type
    assert visa.reload.active?
    assert auto.reload.active?
    profile = @household.household_profile.reload
    assert_equal "summary", profile.debt_tracking_mode
    assert profile.debt_summary_balance_known?
    assert profile.debt_summary_minimum_payment_known?
    assert_equal 18_000_00, profile.debt_summary_balance_cents
    assert_equal 575_00, profile.debt_summary_minimum_payment_cents
    portfolio = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal 18_000_00, portfolio.total_balance_cents
    assert_equal 575_00, portfolio.monthly_minimum_cents
  end

  test "document import history restores independently known balance and minimum facts" do
    payment_only = @household.debts.create!(
      label: "Payment only", debt_type: "medical", balance_cents: 0,
      minimum_payment_cents: 75_00, balance_known: true, minimum_payment_known: true
    )
    balance_only = @household.debts.create!(
      label: "Balance only", debt_type: "auto_loan", balance_cents: 8_000_00,
      minimum_payment_cents: 0, balance_known: true, minimum_payment_known: true
    )
    history = @household.debts.create!(
      label: "History", debt_type: "student_loan", balance_cents: 12_000_00,
      minimum_payment_cents: 175_00, balance_known: true, minimum_payment_known: true
    )
    document_import = create_applied_import
    create_applied_debt_item(document_import, payment_only, balance_cents: nil, payment_cents: 75_00)
    create_applied_debt_item(document_import, balance_only, balance_cents: 8_000_00, payment_cents: nil)
    create_applied_debt_item(document_import, history, balance_cents: 12_000_00, payment_cents: nil, applied_at: 2.days.ago)
    latest = create_applied_debt_item(document_import, history, balance_cents: nil, payment_cents: 175_00, applied_at: 1.day.ago)

    AddDebtLifecycleAndTracking.new.backfill_document_import_provenance!

    assert_not payment_only.reload.balance_known?
    assert payment_only.minimum_payment_known?
    assert balance_only.reload.balance_known?
    assert_not balance_only.minimum_payment_known?
    assert history.reload.balance_known?
    assert history.minimum_payment_known?
    assert_equal latest.id, history.source_metadata.fetch("document_import_item_id")
  end

  test "a setup aggregate matched by a later partial import stays canonical without double counting details" do
    @household.update!(confirmed_setup_fields: %w[credit_card_debt])
    aggregate = @household.debts.create!(
      label: "Credit card debt", debt_type: "credit_card", balance_cents: 10_000_00,
      minimum_payment_cents: 300_00, source_type: "manual_ui"
    )
    @household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 4_000_00,
      minimum_payment_cents: 125_00, source_type: "document_import"
    )
    document_import = create_applied_import
    create_applied_debt_item(document_import, aggregate, balance_cents: nil, payment_cents: 300_00)
    migration = AddDebtLifecycleAndTracking.new

    migration.mark_legacy_setup_aggregates!
    migration.backfill_document_import_provenance!
    migration.reconcile_legacy_setup_debts!

    assert_not aggregate.reload.active?
    assert_equal "setup", aggregate.source_type
    assert aggregate.balance_known?
    assert aggregate.minimum_payment_known?
    portfolio = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal "summary", portfolio.mode
    assert_equal 10_000_00, portfolio.total_balance_cents
    assert_equal 300_00, portfolio.monthly_minimum_cents
  end

  test "an imported generic card label is not mistaken for a setup aggregate" do
    generic = @household.debts.create!(
      label: "Credit card debt", debt_type: "credit_card", balance_cents: 5_000_00,
      minimum_payment_cents: 150_00, source_type: "manual_ui"
    )
    @household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 2_000_00,
      minimum_payment_cents: 75_00, source_type: "document_import"
    )
    document_import = create_applied_import
    create_applied_debt_item(document_import, generic, balance_cents: 5_000_00, payment_cents: 150_00)
    migration = AddDebtLifecycleAndTracking.new

    migration.mark_legacy_setup_aggregates!
    migration.backfill_document_import_provenance!
    migration.reconcile_legacy_setup_debts!

    assert generic.reload.active?
    assert_equal "document_import", generic.source_type
    portfolio = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal "individual", portfolio.mode
    assert_equal 7_000_00, portfolio.total_balance_cents
    assert_equal 225_00, portfolio.monthly_minimum_cents
  end

  test "legacy confirmed zero debt remains a known zero while an unconfirmed empty household stays unknown" do
    @household.update!(confirmed_setup_fields: %w[credit_card_debt debt_payment])
    unconfirmed_user = User.create!(
      clerk_id: "unconfirmed_debt_#{SecureRandom.hex(8)}",
      email: "unconfirmed-debt-#{SecureRandom.hex(8)}@example.com",
      role: "participant", invitation_status: "accepted"
    )
    unconfirmed_household = HouseholdFinance::WorkspaceResolver.new(unconfirmed_user).household
    partial_user = User.create!(
      clerk_id: "partial_debt_#{SecureRandom.hex(8)}",
      email: "partial-debt-#{SecureRandom.hex(8)}@example.com",
      role: "participant", invitation_status: "accepted"
    )
    partial_household = HouseholdFinance::WorkspaceResolver.new(partial_user).household
    partial_household.update!(confirmed_setup_fields: %w[credit_card_debt])

    AddDebtLifecycleAndTracking.new.reconcile_legacy_setup_debts!

    confirmed = HouseholdFinance::DebtPortfolio.new(@household.reload)
    assert_equal "summary", confirmed.mode
    assert confirmed.balance_known?
    assert confirmed.minimum_payment_known?
    assert_equal 0, confirmed.total_balance_cents
    unconfirmed = HouseholdFinance::DebtPortfolio.new(unconfirmed_household.reload)
    assert_equal "individual", unconfirmed.mode
    assert_not unconfirmed.balance_known?
    assert_not unconfirmed.minimum_payment_known?
    partial = HouseholdFinance::DebtPortfolio.new(partial_household.reload)
    assert_equal "summary", partial.mode
    assert partial.balance_known?
    assert_not partial.minimum_payment_known?
  end

  test "case-insensitive active duplicates stop migration for explicit review" do
    connection = ApplicationRecord.connection
    index_name = "index_active_debts_on_household_type_label"
    connection.remove_index(:debts, name: index_name) if connection.index_name_exists?(:debts, index_name)
    timestamp = Time.current
    Debt.insert_all!([
      { household_id: @household.id, label: "Visa", debt_type: "credit_card", balance_cents: 100_00, minimum_payment_cents: 25_00, active: true, archived_at: nil, source_type: "manual_ui", source_metadata: {}, balance_known: true, minimum_payment_known: true, created_at: timestamp, updated_at: timestamp },
      { household_id: @household.id, label: "VISA", debt_type: "credit_card", balance_cents: 200_00, minimum_payment_cents: 35_00, active: true, archived_at: nil, source_type: "manual_ui", source_metadata: {}, balance_known: true, minimum_payment_known: true, created_at: timestamp, updated_at: timestamp }
    ])

    error = assert_raises(ActiveRecord::MigrationError) do
      AddDebtLifecycleAndTracking.new.ensure_no_case_insensitive_active_duplicates!
    end

    assert_includes error.message, "Resolve them explicitly"
  ensure
    Debt.where(household_id: @household&.id, label: %w[Visa VISA]).delete_all if @household
    unless connection&.indexes(:debts)&.any? { |index| index.name == index_name }
      connection.add_index :debts, "household_id, debt_type, lower(label)", unique: true, where: "active = TRUE", name: index_name
    end
  end


  private

  def create_applied_import
    @household.financial_document_imports.create!(
      uploaded_by_user: @user, applied_by_user: @user, applied_at: Time.current,
      document_kind: "statement", status: "applied", filename: "debts.pdf",
      content_type: "application/pdf", byte_size: 100
    )
  end

  def create_applied_debt_item(document_import, debt, balance_cents:, payment_cents:, applied_at: Time.current)
    document_import.items.create!(
      target_type: "debt", label: debt.label, debt_type: debt.debt_type,
      balance_cents: balance_cents, payment_cents: payment_cents,
      confidence: "medium", selected: true, applied_at: applied_at,
      applied_by_user: @user, applied_record: debt
    )
  end
end
