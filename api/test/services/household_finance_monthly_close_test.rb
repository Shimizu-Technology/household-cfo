# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/scorecard/runner")

class HouseholdFinanceMonthlyCloseTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TALUN_TWO_MONTHS = %w[
    checking-2026-10.pdf
    savings-2026-10.pdf
    card-2026-10.pdf
    checking-2026-11.pdf
    savings-2026-11.pdf
    card-2026-11.pdf
  ].freeze

  setup do
    @user = User.create!(
      clerk_id: "monthly-close-#{SecureRandom.hex(8)}",
      email: "monthly-close-#{SecureRandom.hex(8)}@example.invalid",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @household.update_column(:created_at, Time.zone.local(2025, 11, 1, 9, 0, 0))
  end

  test "Talun household closed month matches AnnualBudgetManager actuals, computes variance and movers, and performs zero writes" do
    checked = false
    Scorecard::Runner.new(
      document_paths: TALUN_TWO_MONTHS,
      correct_proposals: false,
      after_review: lambda { |household, _user|
        household.update_column(:created_at, Time.zone.local(2026, 1, 5, 9, 0, 0))
        household.income_sources.create!(label: "Primary pay", source_type: "job", amount_cents: 600_000, cadence: "monthly")
        household.update!(confirmed_setup_fields: %w[primary_income fixed_expenses flexible_spend debt_payment])
        household.household_profile.update!(debt_tracking_mode: "individual")
        household.debts.create!(label: "Mainland Visa", debt_type: "credit_card", balance_cents: 180_000, minimum_payment_cents: 9_000)

        manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
        plan = manager.plan_data
        # Give each category a clean manual allocation for November so planned spending is known.
        nov_period = household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: Date.new(2026, 11, 1))
        household.budget_categories.active.find_each do |cat|
          alloc = BudgetAllocation.find_by!(budget_period: nov_period, budget_category: cat)
          alloc.update!(planned_amount_cents: 50_000, source: "manual")
        end

        refreshed_plan = HouseholdFinance::AnnualBudgetManager.new(household.reload, year: 2026).read_only_plan_data
        before_counts = [
          BudgetYear.count,
          BudgetPeriod.count,
          BudgetAllocation.count,
          HouseholdTransaction.count,
          HouseholdAuditEvent.count
        ]

        close = HouseholdFinance::MonthlyClose.new(
          household,
          year: 2026,
          month: 11,
          annual_plan: refreshed_plan,
          today: Date.new(2026, 12, 10)
        ).call

        assert_equal before_counts, [
          BudgetYear.count,
          BudgetPeriod.count,
          BudgetAllocation.count,
          HouseholdTransaction.count,
          HouseholdAuditEvent.count
        ], "MonthlyClose must perform zero writes"

        assert_equal 2026, close[:year]
        assert_equal 11, close[:month]
        assert_equal "November 2026", close[:period_label]
        assert_equal "October 2026", close[:prior_period_label]
        assert_equal "complete", close[:status]
        assert_equal "Month closed", close[:status_label]

        # Income close matches ActualIncome directly and computes variance and prior-month delta.
        expected_nov_income = HouseholdFinance::ActualIncome.new(household, today: Date.new(2026, 12, 10)).month(Date.new(2026, 11, 1))
        expected_oct_income = HouseholdFinance::ActualIncome.new(household, today: Date.new(2026, 12, 10)).month(Date.new(2026, 10, 1))
        assert_equal 600_000, close.dig(:income, :planned_cents)
        assert_equal expected_nov_income[:actual_cents], close.dig(:income, :actual_cents)
        assert close.dig(:income, :complete)
        assert_equal expected_nov_income[:actual_cents] - 600_000, close.dig(:income, :difference_cents)
        assert_equal expected_oct_income[:actual_cents], close.dig(:income, :prior_month_actual_cents)
        assert_equal expected_nov_income[:actual_cents] - expected_oct_income[:actual_cents], close.dig(:income, :change_from_prior_cents)

        # Spending close matches AnnualBudgetManager cell actuals down to the cent.
        nov_by_id = refreshed_plan[:rows].to_h { |row| [ row[:id], HouseholdFinance::Money.cents(row[:months][10][:actual]) ] }
        oct_by_id = refreshed_plan[:rows].to_h { |row| [ row[:id], HouseholdFinance::Money.cents(row[:months][9][:actual]) ] }
        close[:categories].each do |cat|
          assert_equal nov_by_id.fetch(cat[:id], 0), cat[:actual_cents], "Mismatch for #{cat[:name]}"
          assert_equal oct_by_id.fetch(cat[:id], 0), cat[:prior_actual_cents], "Prior mismatch for #{cat[:name]}"
          assert_equal cat[:actual_cents] - cat[:prior_actual_cents], cat[:change_from_prior_cents]
        end

        expected_actual_spending = nov_by_id.values.sum
        assert_equal expected_actual_spending, close.dig(:totals, :actual_spending_cents)
        assert_equal 9_000, close.dig(:totals, :debt_minimums_cents)
        assert close.dig(:totals, :debt_minimums_known)

        # Net summary computed cleanly when income is complete and spending has activity.
        assert_equal close.dig(:income, :actual_cents) - expected_actual_spending, close.dig(:net, :actual_net_before_debt_cents)
        assert_equal close.dig(:net, :actual_net_before_debt_cents) - 9_000, close.dig(:net, :actual_net_after_debt_cents)

        # Movers & highlights populated honestly.
        assert close.dig(:changes, :prior_month_has_activity)
        assert close.dig(:changes, :increases).length <= 3
        assert close.dig(:changes, :decreases).length <= 3
        assert close[:highlights].length.between?(2, 4)
        checked = true
      }
    ).call
    assert checked
  end

  test "unknown income is never treated as $0 and partial or open months suppress false shortfalls and net cash flow" do
    setup_plan!(year: 2026, primary_income: 5_000)
    groceries = create_category!(year: 2026, name: "Groceries", stack_key: "non_discretionary", amount: 600)
    confirm_purchase!(year: 2026, month: 10, day: 12, category: groceries, merchant: "Payless", amount_cents: 42_000)

    # Past month with spending but NO deposit statements approved -> partial, income actual_cents nil (never $0)
    partial_close = HouseholdFinance::MonthlyClose.new(@household, year: 2026, month: 10, today: Date.new(2026, 11, 5)).call
    assert_equal "partial", partial_close[:status]
    assert_nil partial_close.dig(:income, :actual_cents)
    assert_nil partial_close.dig(:income, :difference_cents)
    assert_nil partial_close.dig(:income, :change_from_prior_cents)
    assert_equal 500_000, partial_close.dig(:income, :planned_cents)
    assert_nil partial_close.dig(:net, :actual_net_before_debt_cents)
    assert_nil partial_close.dig(:net, :actual_net_after_debt_cents)
    assert_equal 42_000, partial_close.dig(:totals, :actual_spending_cents)

    # Open current month -> status "open", income difference_cents nil even if a deposit statement exists
    approve_deposit_statement!(
      year: 2026,
      month: 10,
      period_start: Date.new(2026, 10, 1),
      period_end: Date.new(2026, 10, 31),
      deposits: [ [ Date.new(2026, 10, 15), 250_000 ] ]
    )
    open_close = HouseholdFinance::MonthlyClose.new(@household.reload, year: 2026, month: 10, today: Date.new(2026, 10, 20)).call
    assert_equal "open", open_close[:status]
    assert_equal 250_000, open_close.dig(:income, :actual_cents)
    assert open_close.dig(:income, :month_open)
    assert_nil open_close.dig(:income, :difference_cents), "Open month must not claim an income shortfall"
    assert_nil open_close.dig(:net, :actual_net_before_debt_cents)

    # Future month -> status "future", no fabricated spending variance
    future_close = HouseholdFinance::MonthlyClose.new(@household, year: 2026, month: 12, today: Date.new(2026, 10, 20)).call
    assert_equal "future", future_close[:status]
    assert_nil future_close.dig(:income, :actual_cents)
    assert_nil future_close.dig(:totals, :actual_spending_cents)
    assert_nil future_close.dig(:totals, :spending_difference_cents)

    # Past month with no statements and no spending -> "no_actuals"
    empty_close = HouseholdFinance::MonthlyClose.new(@household, year: 2026, month: 8, today: Date.new(2026, 10, 20)).call
    assert_equal "no_actuals", empty_close[:status]
    assert_nil empty_close.dig(:income, :actual_cents)
    assert_nil empty_close.dig(:totals, :actual_spending_cents)
    assert_nil empty_close.dig(:totals, :spending_difference_cents)
  end

  test "prior month with no activity suppresses fake increases from $0" do
    setup_plan!(year: 2026, primary_income: 5_000)
    groceries = create_category!(year: 2026, name: "Groceries", stack_key: "non_discretionary", amount: 600)
    confirm_purchase!(year: 2026, month: 10, day: 12, category: groceries, merchant: "Payless", amount_cents: 55_000)

    close = HouseholdFinance::MonthlyClose.new(@household, year: 2026, month: 10, today: Date.new(2026, 11, 5)).call
    refute close.dig(:changes, :prior_month_has_activity)
    assert_empty close.dig(:changes, :increases)
    assert_empty close.dig(:changes, :decreases)
    assert_nil close.dig(:totals, :prior_actual_spending_cents)
    assert_nil close.dig(:totals, :spending_change_from_prior_cents)

    groceries_row = close[:categories].find { |cat| cat[:id] == groceries.id }
    assert_nil groceries_row[:prior_actual_cents]
    assert_nil groceries_row[:change_from_prior_cents]
  end

  test "handles refunds including net-negative categories and zero-net activity" do
    setup_plan!(year: 2026, primary_income: 5_000)
    clothing = create_category!(year: 2026, name: "Clothing", stack_key: "discretionary", amount: 150)
    shoes = create_category!(year: 2026, name: "Shoes", stack_key: "discretionary", amount: 100)

    confirm_purchase!(year: 2026, month: 9, day: 10, category: clothing, merchant: "Island Outfitters", amount_cents: 12_000)
    confirm_purchase!(year: 2026, month: 10, day: 5, category: clothing, merchant: "Island Outfitters", amount_cents: 4_000)
    confirm_purchase!(year: 2026, month: 10, day: 6, category: shoes, merchant: "Reef Footwear", amount_cents: 5_000)

    # Approve a $90 refund to Clothing (nets to -$50!) and a $50 refund to Shoes (nets to $0 with activity!)
    approve_refund!(date: Date.new(2026, 10, 12), merchant: "Island Outfitters", amount_cents: 9_000, category: clothing)
    approve_refund!(date: Date.new(2026, 10, 14), merchant: "Reef Footwear", amount_cents: 5_000, category: shoes)

    close = HouseholdFinance::MonthlyClose.new(@household.reload, year: 2026, month: 10, today: Date.new(2026, 11, 5)).call
    clothing_row = close[:categories].find { |cat| cat[:id] == clothing.id }
    shoes_row = close[:categories].find { |cat| cat[:id] == shoes.id }

    assert_equal(-5_000, clothing_row[:actual_cents])
    assert clothing_row[:refund_net_negative]
    assert clothing_row[:has_activity]
    assert_equal(-20_000, clothing_row[:difference_cents])
    assert_equal 12_000, clothing_row[:prior_actual_cents]
    assert_equal(-17_000, clothing_row[:change_from_prior_cents])

    assert_equal 0, shoes_row[:actual_cents]
    refute shoes_row[:refund_net_negative]
    assert shoes_row[:has_activity], "Purchase + equal refund still counts as confirmed activity"
  end

  test "matches AnnualBudgetManager for cash drawdowns across categories" do
    setup_plan!(year: 2026, primary_income: 5_000)
    cash = create_category!(year: 2026, name: "Cash", stack_key: "discretionary", amount: 150)
    dining = create_category!(year: 2026, name: "Dining", stack_key: "discretionary", amount: 200)

    withdrawal_event, _withdrawal_tx = approve_cash_withdrawal!(date: Date.new(2026, 10, 3), amount_cents: 10_000, category: cash)
    lunch_tx = confirm_purchase!(year: 2026, month: 10, day: 5, category: dining, merchant: "Tasi Cafe", amount_cents: 4_000)
    HouseholdFinance::CashDrawdowns.link!(@household, lunch_tx, event_id: withdrawal_event.id, cents: 4_000, user: @user)

    close = HouseholdFinance::MonthlyClose.new(@household.reload, year: 2026, month: 10, today: Date.new(2026, 11, 5)).call
    cash_row = close[:categories].find { |cat| cat[:id] == cash.id }
    dining_row = close[:categories].find { |cat| cat[:id] == dining.id }

    assert_equal 6_000, cash_row[:actual_cents]
    assert_equal 4_000, dining_row[:actual_cents]
    assert_equal 10_000, close.dig(:totals, :actual_spending_cents)
  end

  test "includes archived categories with target or prior activity with $0 plan and excludes quiet archived categories" do
    setup_plan!(year: 2026, primary_income: 5_000)
    groceries = create_category!(year: 2026, name: "Groceries", stack_key: "non_discretionary", amount: 600)
    old_gym = create_category!(year: 2026, name: "Old Gym", stack_key: "discretionary", amount: 80)
    quiet_old = create_category!(year: 2026, name: "Unused Old", stack_key: "discretionary", amount: 50)

    confirm_purchase!(year: 2026, month: 9, day: 10, category: groceries, merchant: "Payless", amount_cents: 50_000)
    confirm_purchase!(year: 2026, month: 10, day: 10, category: groceries, merchant: "Payless", amount_cents: 52_000)
    confirm_purchase!(year: 2026, month: 10, day: 11, category: old_gym, merchant: "Island Fitness", amount_cents: 8_000)

    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    manager.archive_category!(old_gym)
    manager.archive_category!(quiet_old)

    close = HouseholdFinance::MonthlyClose.new(@household.reload, year: 2026, month: 10, today: Date.new(2026, 11, 5)).call
    names = close[:categories].map { |cat| cat[:name] }
    assert_includes names, "Groceries"
    assert_includes names, "Old Gym"
    refute_includes names, "Unused Old"

    archived_row = close[:categories].find { |cat| cat[:id] == old_gym.id }
    refute archived_row[:active]
    assert_equal 0, archived_row[:planned_cents]
    assert_equal 8_000, archived_row[:actual_cents]
    assert_equal 8_000, archived_row[:difference_cents]
    # Planned total sums active categories only (Groceries 600 + default setup rows if any).
    expected_planned = close[:categories].select { |c| c[:active] }.sum { |c| c[:planned_cents] }
    assert_equal expected_planned, close.dig(:totals, :planned_spending_cents)
  end

  test "handles Jan to Dec year boundary cleanly including prior-year-only archived category and income change" do
    setup_plan!(year: 2025, primary_income: 5_000)
    setup_plan!(year: 2026, primary_income: 5_200)
    groceries = create_category!(year: 2026, name: "Groceries", stack_key: "non_discretionary", amount: 600)
    holiday = create_category!(year: 2025, name: "Holiday Gifts", stack_key: "sinking_expected", amount: 300)

    confirm_purchase!(year: 2025, month: 12, day: 15, category: groceries, merchant: "Payless", amount_cents: 70_000)
    confirm_purchase!(year: 2025, month: 12, day: 20, category: holiday, merchant: "Micronesia Mall", amount_cents: 45_000)
    confirm_purchase!(year: 2026, month: 1, day: 10, category: groceries, merchant: "Payless", amount_cents: 58_000)

    HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).archive_category!(holiday)

    approve_deposit_statement!(
      year: 2025,
      month: 12,
      period_start: Date.new(2025, 12, 1),
      period_end: Date.new(2025, 12, 31),
      deposits: [ [ Date.new(2025, 12, 15), 500_000 ] ]
    )
    approve_deposit_statement!(
      year: 2026,
      month: 1,
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 1, 31),
      deposits: [ [ Date.new(2026, 1, 15), 540_000 ] ]
    )

    close = HouseholdFinance::MonthlyClose.new(@household.reload, year: 2026, month: 1, today: Date.new(2026, 2, 10)).call
    assert_equal 2025, close[:prior_year]
    assert_equal 12, close[:prior_month]
    assert_equal "December 2025", close[:prior_period_label]
    assert_equal "complete", close[:status]
    assert_equal 40_000, close.dig(:income, :change_from_prior_cents)
    assert_equal 40_000, close.dig(:changes, :income_change, :change_from_prior_cents)

    holiday_row = close[:categories].find { |cat| cat[:id] == holiday.id }
    assert_not_nil holiday_row, "Archived category with December activity should appear in January close"
    assert_equal 0, holiday_row[:actual_cents]
    assert_equal 45_000, holiday_row[:prior_actual_cents]
    assert_equal(-45_000, holiday_row[:change_from_prior_cents])
    assert_equal holiday.id, close.dig(:changes, :decreases, 0, :category_id)
  end

  test "respects program method expense group names and hides plan before plan_starts_on" do
    setup_plan!(year: 2026, primary_income: 5_000)
    create_category!(year: 2026, name: "Rent", stack_key: "non_discretionary", amount: 1_650)

    method_close = HouseholdFinance::MonthlyClose.new(
      @household,
      year: 2026,
      month: 10,
      method: { "group_names" => "method" },
      today: Date.new(2026, 11, 5)
    ).call
    rent_row = method_close[:categories].find { |cat| cat[:name] == "Rent" }
    assert_equal "Non-discretionary", rent_row[:stack_label]

    plain_close = HouseholdFinance::MonthlyClose.new(
      @household,
      year: 2026,
      month: 10,
      method: { "group_names" => "plain" },
      today: Date.new(2026, 11, 5)
    ).call
    assert_equal "Must-pay bills", plain_close[:categories].find { |cat| cat[:name] == "Rent" }[:stack_label]

    # Before plan_starts_on (household created_at is Nov 2025, so Oct 2025 is before plan start)
    before_close = HouseholdFinance::MonthlyClose.new(@household, year: 2025, month: 10, today: Date.new(2026, 11, 5)).call
    assert before_close[:before_plan_start]
    assert_nil before_close.dig(:income, :planned_cents)
    assert_nil before_close.dig(:totals, :planned_spending_cents)
    refute before_close.dig(:totals, :debt_minimums_known)
  end

  private

  def setup_plan!(year:, primary_income:)
    unless @household.income_sources.where(source_type: "job").exists?
      @household.income_sources.create!(label: "Primary pay", source_type: "job", amount_cents: primary_income * 100, cadence: "monthly")
    end
    @household.update!(confirmed_setup_fields: (%w[primary_income fixed_expenses flexible_spend debt_payment] + Array(@household.confirmed_setup_fields)).uniq)
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_minimum_payment_cents: 0)
    HouseholdFinance::AnnualBudgetManager.new(@household, year: year).ensure_plan!
  end

  def create_category!(year:, name:, stack_key:, amount:)
    HouseholdFinance::AnnualBudgetManager.new(@household, year: year).create_category!(name: name, stack_key: stack_key, monthly_amount: amount)
  end

  def confirm_purchase!(year:, month:, day:, category:, merchant:, amount_cents:)
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: year)
    manager.ensure_plan!
    period = @household.budget_years.find_by!(year: year).budget_periods.find_by!(starts_on: Date.new(year, month, 1))
    tx = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(year, month, day),
      merchant: merchant,
      total_amount_cents: amount_cents,
      status: "confirmed",
      source_type: "manual_ui"
    )
    tx.transaction_splits.create!(budget_category: category, amount_cents: amount_cents)
    tx
  end

  def run_source_op(klass, input)
    operation = klass.new(@household, user: @user)
    ApplicationRecord.transaction do
      @household.lock!
      prepared = operation.prepare(input)
      operation.execute!(prepared, source: "manual")
    end
  end

  def approve_deposit_statement!(year:, month:, period_start:, period_end:, deposits:)
    import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      filename: "checking-#{year}-#{format('%02d', month)}.pdf",
      document_kind: "statement",
      content_type: "application/pdf",
      byte_size: 1200,
      status: "needs_review",
      s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf",
      checksum_sha256: SecureRandom.hex(32)
    )
    attempt = import.attempts.create!(
      provider: "synthetic",
      model: "synthetic",
      prompt_version: "v1",
      schema_version: 2,
      status: "processing",
      started_at: Time.current
    )
    total_credit = deposits.sum { |(_, cents)| cents }
    events_payload = deposits.each_with_index.map do |(posted_on, cents), index|
      {
        account_key: "checking-4410",
        row_kind: "posted",
        limitations: [],
        event_type: "income",
        signed_amount_cents: cents,
        posted_on: posted_on.iso8601,
        merchant: "Direct Deposit Payroll",
        locator: { page: 1, row: index + 1 }
      }
    end
    accounting = FinancialDocuments::AccountingContract.normalize(
      {
        contract_version: FinancialDocuments::AccountingContract::VERSION,
        accounts: [ {
          account_key: "checking-4410",
          account_basis: "asset",
          label: "Everyday Checking",
          period_start_on: period_start.iso8601,
          period_end_on: period_end.iso8601,
          opening_balance_cents: 100_000,
          closing_balance_cents: 100_000 + total_credit,
          printed_debit_cents: 0,
          printed_credit_cents: total_credit,
          printed_row_count: deposits.length
        } ],
        events: events_payload,
        reported_row_count: deposits.length
      },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] }
    )
    persisted = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    account = persisted[:revision].financial_source_accounts.sole
    tracked = SourceTrackedAccount.find_by(household: @household, label: "Everyday Checking")
    identity = run_source_op(
      HouseholdFinance::Operations::SourceReview::AccountLink,
      source_account_id: account.id,
      account_basis: "asset",
      label: "Everyday Checking",
      tracked_account_id: tracked&.id,
      base_version_id: nil,
      base_lock_version: 0,
      statement_facts: account.attributes.slice(
        "period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents",
        "printed_debit_cents", "printed_credit_cents", "printed_row_count"
      ),
      reason: "Reviewed checking statement header"
    )

    persisted[:events].each_with_index do |event, index|
      posted_on, cents = deposits[index]
      draft = run_source_op(
        HouseholdFinance::Operations::SourceReview::DraftStage,
        event_id: event.id,
        base_version_id: nil,
        base_lock_version: 0,
        reason: "Reviewed deposit",
        projection: { action: "none" },
        facts: {
          source_account_identity_version_id: identity.id,
          disposition: "include",
          event_type: "income",
          signed_amount_cents: cents,
          purchase_amount_cents: nil,
          posted_on: posted_on.iso8601,
          merchant: "Direct Deposit Payroll",
          overlap_disposition: "distinct",
          matched_version_id: nil
        }
      )
      run_source_op(
        HouseholdFinance::Operations::SourceReview::DraftApprove,
        draft_id: draft.id,
        draft_lock_version: draft.lock_version,
        draft_digest: draft.digest
      )
    end

    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, persisted[:revision]).call
    run_source_op(
      HouseholdFinance::Operations::SourceReview::RevisionApprove,
      revision_id: persisted[:revision].id,
      requested_status: "complete",
      expected_digest: state[:content_digest],
      reason: "Complete checking statement",
      coverage_attestation: {
        all_document_rows_accounted: true,
        accounts: [ {
          source_account_id: account.id,
          identity_version_id: identity.id,
          period_start_on: period_start.iso8601,
          period_end_on: period_end.iso8601,
          all_rows_accounted: true
        } ]
      }
    )
  end

  def approve_refund!(date:, merchant:, amount_cents:, category:)
    import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      filename: "card-refund-#{date.iso8601}.pdf",
      document_kind: "statement",
      content_type: "application/pdf",
      byte_size: 1000,
      status: "needs_review",
      s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf",
      checksum_sha256: SecureRandom.hex(32)
    )
    attempt = import.attempts.create!(
      provider: "synthetic",
      model: "synthetic",
      prompt_version: "v1",
      schema_version: 2,
      status: "processing",
      started_at: Time.current
    )
    accounting = FinancialDocuments::AccountingContract.normalize(
      {
        contract_version: FinancialDocuments::AccountingContract::VERSION,
        accounts: [ {
          account_key: "card-6074",
          account_basis: "liability",
          label: "Mainland Visa",
          period_start_on: date.beginning_of_month.iso8601,
          period_end_on: date.end_of_month.iso8601
        } ],
        events: [ {
          account_key: "card-6074",
          row_kind: "posted",
          limitations: [],
          event_type: "refund",
          signed_amount_cents: amount_cents,
          posted_on: date.iso8601,
          merchant: merchant,
          locator: { page: 1, row: 1 }
        } ],
        reported_row_count: 1
      },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] }
    )
    persisted = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    account = persisted[:revision].financial_source_accounts.sole
    tracked = SourceTrackedAccount.find_by(household: @household, label: "Mainland Visa")
    identity = run_source_op(
      HouseholdFinance::Operations::SourceReview::AccountLink,
      source_account_id: account.id,
      account_basis: "liability",
      label: "Mainland Visa",
      tracked_account_id: tracked&.id,
      base_version_id: nil,
      base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on"),
      reason: "Reviewed card statement header"
    )
    event = persisted[:events].sole
    draft = run_source_op(
      HouseholdFinance::Operations::SourceReview::DraftStage,
      event_id: event.id,
      base_version_id: nil,
      base_lock_version: 0,
      reason: "Reviewed refund",
      projection: { action: "none" },
      facts: {
        source_account_identity_version_id: identity.id,
        disposition: "include",
        event_type: "refund",
        signed_amount_cents: amount_cents,
        purchase_amount_cents: nil,
        posted_on: date.iso8601,
        merchant: merchant,
        budget_category_id: category.id,
        overlap_disposition: "distinct",
        matched_version_id: nil
      }
    )
    run_source_op(
      HouseholdFinance::Operations::SourceReview::DraftApprove,
      draft_id: draft.id,
      draft_lock_version: draft.lock_version,
      draft_digest: draft.digest
    )
  end

  def approve_cash_withdrawal!(date:, amount_cents:, category:)
    import = FinancialDocumentImport.create!(
      household: @household,
      uploaded_by_user: @user,
      filename: "atm-#{date.iso8601}.pdf",
      document_kind: "statement",
      content_type: "application/pdf",
      byte_size: 1000,
      status: "needs_review",
      s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf",
      checksum_sha256: SecureRandom.hex(32)
    )
    attempt = import.attempts.create!(
      provider: "synthetic",
      model: "synthetic",
      prompt_version: "v1",
      schema_version: 2,
      status: "processing",
      started_at: Time.current
    )
    accounting = FinancialDocuments::AccountingContract.normalize(
      {
        contract_version: FinancialDocuments::AccountingContract::VERSION,
        accounts: [ {
          account_key: "checking-4410",
          account_basis: "asset",
          label: "Everyday Checking",
          period_start_on: date.beginning_of_month.iso8601,
          period_end_on: date.end_of_month.iso8601
        } ],
        events: [ {
          account_key: "checking-4410",
          row_kind: "posted",
          limitations: [],
          event_type: "cash_withdrawal",
          signed_amount_cents: -amount_cents,
          posted_on: date.iso8601,
          merchant: "ATM Withdrawal",
          locator: { page: 1, row: 1 }
        } ],
        reported_row_count: 1
      },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] }
    )
    persisted = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    account = persisted[:revision].financial_source_accounts.sole
    tracked = SourceTrackedAccount.find_by(household: @household, label: "Everyday Checking")
    identity = run_source_op(
      HouseholdFinance::Operations::SourceReview::AccountLink,
      source_account_id: account.id,
      account_basis: "asset",
      label: "Everyday Checking",
      tracked_account_id: tracked&.id,
      base_version_id: nil,
      base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on"),
      reason: "Reviewed checking statement header"
    )
    event = persisted[:events].sole
    draft = run_source_op(
      HouseholdFinance::Operations::SourceReview::DraftStage,
      event_id: event.id,
      base_version_id: nil,
      base_lock_version: 0,
      reason: "Reviewed ATM withdrawal",
      projection: { action: "none" },
      facts: {
        source_account_identity_version_id: identity.id,
        disposition: "include",
        event_type: "cash_withdrawal",
        signed_amount_cents: -amount_cents,
        purchase_amount_cents: amount_cents,
        posted_on: date.iso8601,
        merchant: "ATM Withdrawal",
        budget_category_id: category.id,
        overlap_disposition: "distinct",
        matched_version_id: nil
      }
    )
    run_source_op(
      HouseholdFinance::Operations::SourceReview::DraftApprove,
      draft_id: draft.id,
      draft_lock_version: draft.lock_version,
      draft_digest: draft.digest
    )

    period = @household.budget_years.find_by!(year: date.year).budget_periods.find_by!(starts_on: date.beginning_of_month)
    tx = @household.household_transactions.create!(
      budget_period: period,
      financial_source_event: event,
      occurred_on: date,
      merchant: "ATM Withdrawal",
      total_amount_cents: amount_cents,
      status: "confirmed",
      source_type: "statement"
    )
    tx.transaction_splits.create!(budget_category: category, amount_cents: amount_cents)
    [ event, tx ]
  end
end
