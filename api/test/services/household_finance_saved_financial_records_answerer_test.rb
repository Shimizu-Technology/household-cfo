require "test_helper"

class HouseholdFinanceSavedFinancialRecordsAnswererTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "saved_reads_#{SecureRandom.hex(6)}", email: "saved-reads-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Saved records household")
    @household.household_memberships.create!(user: @user, role: "owner")
  end

  test "inventory honors changed cadence one-time income future and ended sources without creating a plan" do
    salary = income("Salary", 400_000)
    salary.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 200_000, cadence: "biweekly", effective_on: "2026-09-01")
    salary.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus", amount_cents: 25_000, cadence: "one_time", effective_on: "2026-10-01")
    salary.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 250_000, cadence: "biweekly", effective_on: "2026-12-01")
    income("Future rental", 80_000, starts_on: "2026-11-01", source_type: "rental")
    income("Ended tutoring", 30_000, active: false, starts_on: "2026-01-01", ends_on: "2026-10-01", source_type: "other")
    expected = HouseholdFinance::IncomeTimeline.period_cents(salary, starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 31))
    assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "BudgetCategory.count", "HouseholdProfile.count", "MiaActionDraft.count", "HouseholdTransaction.count" ] do
      response = answer("List all my saved income sources, amounts, cadence and upcoming changes. Do not change anything.")
      assert_equal "income", response.metadata[:topic]
      assert_equal expected / 100.0, response.metadata[:selected_month_amount]
      assert_includes response.answer, "base $4,000.00 per month; effective $2,000.00 every two weeks"
      assert_includes response.answer, "2026-10-01: one-time — Bonus, $250.00"
      assert_includes response.answer, "2026-12-01: recurring change, $2,500.00"
      assert_includes response.answer, "Status: future"
      assert_includes response.answer, "Ends before 2026-10-01"
      assert_includes response.answer, "Status: ended"
      assert_includes response.answer, "not verified deposits or pay dates"
    end
  end

  test "empty income inventory is unknown while explicitly saved zero remains zero" do
    response = answer("What are my income sources?")
    assert_includes response.answer, "income is unknown"
    assert_nil response.metadata[:selected_month_amount]
    income("Paused source", 0)
    response = answer("What is my income?")
    assert_includes response.answer, "$0.00"
    assert_equal 0.0, response.metadata[:selected_month_amount]
  end

  test "relative month uses calendar and named month uses requested period" do
    travel_to Time.zone.local(2026, 10, 6, 12) do
      salary = income("Salary", 100_000)
      salary.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 200_000, cadence: "monthly", effective_on: "2026-11-01")
      assert_equal "2026-11-01", answer("Show my income next month", year: 2025, month: 2).metadata[:reference_month]
      assert_equal 2000.0, answer("Show my income next month", year: 2025, month: 2).metadata[:selected_month_amount]
      assert_equal "2026-10-01", answer("Show my income this month", year: 2025, month: 2).metadata[:reference_month]
      assert_equal "2026-10-01", answer("Show my income today", year: 2025, month: 2).metadata[:reference_month]
      assert_equal "2027-01-01", answer("Show my income for January 2027").metadata[:reference_month]
      assert_nil answer("Compare my income in October and November")
      assert_nil answer("Show my income this month and next month")
      assert_nil answer("Show my income next year")
      assert_nil answer("Show my annual income")
    end
  end

  test "read detection leaves actions advice challenge records documents and multi-domain reads to their routers" do
    [ "Create an income source", "What if my income increases?", "Show my income and update Salary to $5000", "How much should I pay toward debt?", "Show my income from this statement", "List my challenge savings goals", "What is my savings progress?", "What is my savings goal?", "What does this uploaded account show?", "Show my income and debts", "Which debt is best to pay first?", "List my income and create a goal", "What are my credit cards and their statement APRs?" ].each do |message|
      assert_nil answer(message), message
    end
    assert answer("Where does my income come from?")
    assert answer("Tell me my saved household debt balances")
    assert answer("List my saved household accounts")
    assert answer("What are my tracked household goals?")
  end

  test "numeric requested periods override the selected month with matching income truth" do
    salary = income("Salary", 100_000)
    salary.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 250_000, cadence: "monthly", effective_on: "2026-12-01")
    [ "Show my income for 2026-12", "Show my income for 2026-12-01", "Show my income for 2026-12-31", "Show my income for December 2026 (2026-12)" ].each do |message|
      assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "MiaActionDraft.count", "HouseholdTransaction.count", "IncomeSource.count", "IncomeScheduleEntry.count" ] do
        response = answer(message, year: 2026, month: 10)
        assert_equal "2026-12-01", response.metadata[:reference_month], message
        assert_equal 2500.0, response.metadata[:selected_month_amount], message
        assert_includes response.answer, "December 2026"
        assert_not_includes response.answer, "October 2026"
      end
    end
  end

  test "invalid conflicting and ambiguous numeric periods fall through without writes" do
    [ "Show my income for 2026-13", "Show my income for 2026-02-30", "Show my income for 2026-1", "Show my income for 2026-12-1", "Show my income for 2026-12-", "Show my income for 2026-12-001", "Show my income for 2026-12-01T12:00:00", "Show my income for 2026–12", "Show my income for 2200-12", "Show my income for 12/2026", "Show my income for 12/01/2026", "Show my income for 2026-12 and 2027-01", "Show my income for November 2026 (2026-12)", "Show my income for December 2027 (2026-12)", "Show my income this month (2026-12)" ].each do |message|
      assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "MiaActionDraft.count", "HouseholdTransaction.count" ] do
        assert_nil answer(message), message
      end
    end
  end

  test "mixed read write requests and scoped negation fall through for complete intent handling" do
    [ "Show my income and reduce Dining by $20 for October", "List my accounts and transfer $10 between them", "Show my income then adjust Dining to $20", "Show my income and shift $10 from Dining to Groceries", "Show my income and make Dining $20", "Show my income and edit Dining", "Show my income and reclassify Dining", "Show my income and recategorize Dining", "Show my income; do not change income but reduce Dining by $20", "Show my income without changing it but edit Dining", "Show my income and reduce Dining by $20. Do not change anything.", "Show my income, don't update income, but make Dining $20" ].each do |message|
      assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "MiaActionDraft.count", "HouseholdTransaction.count", "IncomeSource.count" ] do
        assert_nil answer(message), message
      end
    end
    assert answer("Show my income. Do not change anything.")
  end

  test "read totals include omitted records and schedule omission is visible" do
    22.times { |index| income("Source #{index.to_s.rjust(2, '0')}", 100) }
    salary = @household.income_sources.first
    8.times do |index|
      salary.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus #{index}", amount_cents: 100, cadence: "one_time", effective_on: Date.new(2026, 10, 1).next_month(index))
    end
    response = answer("List all my income sources")
    assert_equal 22, response.metadata[:total_count]
    assert_equal 20, response.metadata[:shown_count]
    assert_equal 23.0, response.metadata[:selected_month_amount]
    assert_includes response.answer, "Showing 20 of 22"
    assert_includes response.answer, "Showing 6 of 8 current and future entries"
  end

  test "household debts keep unknown and zero distinct and do not read optional challenge cards" do
    @household.debts.create!(label: "Unknown Visa", debt_type: "credit_card", balance_cents: 0, balance_known: false, minimum_payment_cents: 0, minimum_payment_known: false)
    @household.debts.create!(label: "Paid card", debt_type: "credit_card", balance_cents: 0, balance_known: true, minimum_payment_cents: 0, minimum_payment_known: true, interest_rate_percent: 0)
    assert_no_difference "HouseholdProfile.count" do
      response = answer("List my household debt balances")
      assert_includes response.answer, "Unknown Visa (Credit card): balance unknown, monthly minimum unknown, APR unknown"
      assert_includes response.answer, "Paid card (Credit card): balance $0.00, monthly minimum $0.00, APR 0.0%"
      assert_includes response.answer, "separate from the challenge's optional card-term review"
    end
  end

  test "summary debt mode excludes preserved individual balances" do
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 450_000, debt_summary_balance_known: true, debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: false)
    @household.debts.create!(label: "Preserved Visa", debt_type: "credit_card", balance_cents: 999_999, minimum_payment_cents: 20_000)
    response = answer("What is my household debt?")
    assert_includes response.answer, "balance $4,500.00, monthly minimum unknown"
    assert_not_includes response.answer, "Preserved Visa"
    assert_not_includes response.answer, "$9,999.99"
  end

  test "account inventory is saved not live and preserves negative and unknown balances" do
    @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: -1000, balance_as_of_on: "2026-10-03")
    @household.accounts.create!(label: "Unknown savings", account_type: "savings", balance_cents: 0, balance_known: false)
    response = answer("List my accounts")
    assert_includes response.answer, "Checking (Checking): balance -$10.00 as of 2026-10-03"
    assert_includes response.answer, "Unknown savings (Savings): balance unknown"
    assert_includes response.answer, "not verified live bank balances"
  end

  test "tracked goal inventory excludes policy records and preserves unknown targets" do
    @household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6)
    @household.goals.create!(label: "Travel", goal_type: "travel", target_amount_cents: 0, target_amount_known: false, current_amount_cents: 0, current_amount_known: true)
    response = answer("List my tracked household goals")
    assert_includes response.answer, "Travel (Travel): target unknown, recorded progress $0.00"
    assert_not_includes response.answer, "Runway"
    assert_includes response.answer, "do not move money"
  end

  test "reader is household scoped and does not reuse chat assertions" do
    income("Our salary", 100_000)
    another = Household.create!(created_by_user: @user, name: "Other household")
    another.income_sources.create!(label: "Private salary", source_type: "job", amount_cents: 900_000, cadence: "monthly", active: true)
    response = answer("Show my income sources")
    assert_includes response.answer, "Our salary"
    assert_not_includes response.answer, "Private salary"
    assert_equal 1000.0, response.metadata[:selected_month_amount]
  end

  test "spending inventory separates saved plan recorded actuals and pending proposed category amounts" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    period = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: "2026-10-01")
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: "2026-10-02", merchant: "Recorded cafe", total_amount_cents: 2500, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: dining, amount_cents: 2500)
    draft = @household.transaction_drafts.create!(budget_category: dining, occurred_on: "2026-10-03", merchant: "Pending cafe", total_amount_cents: 1000, source_type: "manual_ui", status: "pending")
    draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 1000)
    @household.transaction_drafts.create!(occurred_on: "2026-10-04", merchant: "Unassigned review", total_amount_cents: 500, source_type: "manual_ui", status: "pending")
    assert_read_financial_records_unchanged do
      response = answer("Show my household spending categories and planned amounts")
      assert_equal "spending", response.metadata[:topic]
      assert_includes response.answer, "Dining Out — Discretionary: saved monthly plan $300.00; confirmed actuals recorded $25.00; pending proposed category spending $10.00, excluded from actuals"
      assert_includes response.answer, "2 pending household transaction reviews"
      assert_includes response.answer, "totaling $15.00"
      assert_includes response.answer, "does not verify no spending or complete coverage"
      assert_includes response.answer, "separate from the challenge's approved spending baseline"
    end
  end

  test "targeted spending reads use unique category and requested future and numeric period" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    manager.create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 100)
    dining_out = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    november = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: "2026-11-01")
    december = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: "2026-12-01")
    manager.update_allocation!(dining_out.budget_allocations.find_by!(budget_period: november), 450)
    manager.update_allocation!(dining_out.budget_allocations.find_by!(budget_period: december), 500)
    travel_to Time.zone.local(2026, 10, 6, 12) do
      assert_read_financial_records_unchanged do
        response = answer("What is my household Dining Out budget next month?")
        assert_equal "2026-11-01", response.metadata[:reference_month]
        assert_equal 1, response.metadata[:total_count]
        assert_equal 450.0, response.metadata[:records].sole[:planned_amount]
        assert_not_includes response.answer, "Dining —"
        assert_equal 500.0, answer("Show my household Dining Out budget for 2026-12").metadata[:records].sole[:planned_amount]
        assert_equal "ambiguous_category", answer("Show my household Dining and Dining Out budget").metadata[:coverage]
        assert_equal "category_not_found", answer("What is my household Travel budget?").metadata[:coverage]
      end
    end
  end

  test "no-plan spending preview qualifies setup estimates and never claims actual or allocation coverage" do
    @household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", amount_cents: 80_000, cadence: "monthly", active: true)
    @household.budget_categories.create!(name: "Unplanned category", stack_key: "discretionary", active: true, sort_order: 0)
    assert_read_financial_records_unchanged do
      response = answer("Show my household spending categories and planned amounts")
      refute response.metadata[:plan_available]
      assert_includes response.answer, "No saved monthly budget plan"
      assert_includes response.answer, "Rent — Non-discretionary: no saved monthly allocation; setup starting estimate $800.00 (not approved for this month)"
      assert_includes response.answer, "Unplanned category — Discretionary: no saved monthly allocation; planned amount unknown"
      assert_includes response.answer, "confirmed actuals unavailable in this plan preview"
      assert_not_includes response.answer, "confirmed actuals recorded $0.00"
      assert response.metadata[:records].all? { |row| row[:planned_amount].nil? && row[:confirmed_actual_amount].nil? }
    end
  end

  test "missing saved allocation is not converted into approved zero" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    category = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    period = @household.budget_years.find_by!(year: 2026).budget_periods.find_by!(starts_on: "2026-10-01")
    category.budget_allocations.find_by!(budget_period: period).destroy!
    assert_read_financial_records_unchanged do
      response = answer("What is my household Dining Out budget?")
      assert response.metadata[:plan_available]
      assert_nil response.metadata[:records].sole[:planned_amount]
      assert_equal 300.0, response.metadata[:records].sole[:starting_estimate]
      assert_includes response.answer, "no saved monthly allocation; setup starting estimate $300.00"
      assert_not_includes response.answer, "saved monthly plan $0.00"
    end
  end

  test "bounded category inventory preserves complete total and targeted lookup beyond first page" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    22.times { |index| manager.create_category!(name: "Category #{index.to_s.rjust(2, '0')}", stack_key: "discretionary", monthly_amount: 1) }
    assert_read_financial_records_unchanged do
      response = answer("Show my household spending categories and planned amounts")
      assert_equal 22, response.metadata[:total_count]
      assert_equal 20, response.metadata[:shown_count]
      assert_includes response.answer, "Showing 20 of 22"
      assert_includes response.answer, "across all 22 categories: $22.00"
      targeted = answer("What is my household Category 21 budget?")
      assert_equal "Category 21", targeted.metadata[:records].sole[:name]
      assert_equal 1.0, targeted.metadata[:records].sole[:planned_amount]
    end
  end

  test "archived category historical zero is retained as a recorded zero not a no-spend claim" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    category = manager.create_category!(name: "Old Dining", stack_key: "discretionary", monthly_amount: 100)
    year = @household.budget_years.find_by!(year: 2026)
    june = year.budget_periods.find_by!(starts_on: "2026-06-01")
    october = year.budget_periods.find_by!(starts_on: "2026-10-01")
    transaction = @household.household_transactions.create!(budget_period: june, occurred_on: "2026-06-02", merchant: "Historical cafe", total_amount_cents: 1000, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1000)
    manager.update_allocation!(category.budget_allocations.find_by!(budget_period: october), 0)
    manager.archive_category!(category)
    assert_read_financial_records_unchanged do
      response = answer("What is my household Old Dining budget for 2026-10?")
      assert_includes response.answer, "archived category retained for history"
      assert_includes response.answer, "saved monthly plan $0.00; confirmed actuals recorded $0.00"
      assert_includes response.answer, "A recorded $0 does not verify no spending"
    end
  end

  test "spending advice baseline documents scenarios and mixed writes stay outside saved spending reads" do
    [ "Show my household spending categories and reduce Dining by $20", "What is my household spending baseline?", "What should my household Dining Out budget be?", "Show my household categories from the uploaded statement", "What if my household Dining budget were $500?" ].each do |message|
      assert_read_financial_records_unchanged { assert_nil answer(message), message }
    end
  end

  private

  def income(label, cents, **attributes)
    @household.income_sources.create!({ label: label, source_type: "job", amount_cents: cents, cadence: "monthly", active: true }.merge(attributes))
  end

  def answer(message, year: 2026, month: 10)
    HouseholdFinance::SavedFinancialRecordsAnswerer.new(@household, message: message, year: year, month: month).call
  end

  def assert_read_financial_records_unchanged(&block)
    assert_no_difference [ "BudgetYear.count", "BudgetPeriod.count", "BudgetCategory.count", "BudgetAllocation.count", "HouseholdProfile.count", "ExpenseItem.count", "IncomeSource.count", "IncomeScheduleEntry.count", "MiaActionDraft.count", "HouseholdTransaction.count", "TransactionDraft.count" ], &block
  end
end
