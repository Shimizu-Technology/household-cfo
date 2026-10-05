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
      assert_equal "2027-01-01", answer("Show my income for January 2027").metadata[:reference_month]
      assert_nil answer("Compare my income in October and November")
      assert_nil answer("Show my income this month and next month")
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

  private

  def income(label, cents, **attributes)
    @household.income_sources.create!({ label: label, source_type: "job", amount_cents: cents, cadence: "monthly", active: true }.merge(attributes))
  end

  def answer(message, year: 2026, month: 10)
    HouseholdFinance::SavedFinancialRecordsAnswerer.new(@household, message: message, year: year, month: month).call
  end
end
