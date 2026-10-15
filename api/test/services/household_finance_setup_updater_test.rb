require "test_helper"

class HouseholdFinanceSetupUpdaterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "setup-updater-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Setup updater household")
  end

  test "a new fixed total scales annual items in their own cadence" do
    rent = add_expense("Rent", 120_000, "monthly")
    insurance = add_expense("Car insurance", 120_000, "annual")

    update_fixed_expenses("1430")

    assert_expense rent, amount_cents: 132_000, cadence: "monthly", active: true
    assert_expense insurance, amount_cents: 132_000, cadence: "annual", active: true
    assert_equal 143_000, fixed_monthly_equivalent_cents
  end

  test "one-time items stay untouched and active when the total changes" do
    rent = add_expense("Rent", 50_000, "monthly")
    registration = add_expense("Car registration", 25_000, "one_time")

    update_fixed_expenses("600")

    assert_expense rent, amount_cents: 60_000, cadence: "monthly", active: true
    assert_expense registration, amount_cents: 25_000, cadence: "one_time", active: true
  end

  test "a single weekly item stays weekly" do
    groceries = add_expense("Groceries", 10_000, "weekly", stack_key: "discretionary")

    HouseholdFinance::SetupUpdater.new(@household, flexible_spend: "650").call

    assert_expense groceries, amount_cents: 15_000, cadence: "weekly", active: true
  end

  test "a single annual item stays annual" do
    insurance = add_expense("Car insurance", 120_000, "annual")

    update_fixed_expenses("150")

    assert_expense insurance, amount_cents: 180_000, cadence: "annual", active: true
  end

  test "mixed weekly and monthly items keep their cadences and land on the exact total" do
    groceries = add_expense("Groceries", 10_000, "weekly")
    rent = add_expense("Rent", 20_000, "monthly")
    utilities = add_expense("Utilities", 5_000, "biweekly")

    update_fixed_expenses("1234.57")

    assert_equal "weekly", groceries.reload.cadence
    assert_equal "monthly", rent.reload.cadence
    assert_equal "biweekly", utilities.reload.cadence
    assert_equal 123_457, fixed_monthly_equivalent_cents
  end

  test "an unchanged total is a no-op even when an annual amount leaves a remainder month" do
    travel_to Date.new(Date.current.year, 1, 15) do
      rent = add_expense("Rent", 10_000, "monthly")
      dues = add_expense("Club dues", 1_000, "annual")
      # January gets the extra cent of the annual remainder, so the period view
      # reads $100.84 while the monthly equivalent is $100.83.
      assert_equal 10_084, HouseholdFinance::Money.period_cents(10_000, "monthly", month: 1) + HouseholdFinance::Money.period_cents(1_000, "annual", month: 1)
      before = [ rent.reload.updated_at, dues.reload.updated_at ]

      update_fixed_expenses("100.83")

      assert_expense rent, amount_cents: 10_000, cadence: "monthly", active: true
      assert_expense dues, amount_cents: 1_000, cadence: "annual", active: true
      assert_equal before, [ rent.reload.updated_at, dues.reload.updated_at ]
    end
  end

  test "a one-cent nudge keeps an annual amount whose monthly share did not change" do
    rent = add_expense("Rent", 10_000, "monthly")
    dues = add_expense("Club dues", 1_000, "annual")

    update_fixed_expenses("100.84")

    assert_expense rent, amount_cents: 10_001, cadence: "monthly", active: true
    assert_expense dues, amount_cents: 1_000, cadence: "annual", active: true
  end

  test "a zero total pauses recurring items without changing their cadence and leaves one-time items alone" do
    rent = add_expense("Rent", 120_000, "monthly")
    insurance = add_expense("Car insurance", 120_000, "annual")
    registration = add_expense("Car registration", 15_000, "one_time")

    update_fixed_expenses("0")

    assert_expense rent, amount_cents: 0, cadence: "monthly", active: false
    assert_expense insurance, amount_cents: 0, cadence: "annual", active: false
    assert_expense registration, amount_cents: 15_000, cadence: "one_time", active: true
  end

  test "a stack with only one-time items refuses a new monthly total and changes nothing" do
    registration = add_expense("Car registration", 15_000, "one_time")

    error = assert_raises(ArgumentError) { update_fixed_expenses("300") }

    assert_equal "Fixed essentials only has one-time expenses saved, so there is no regular monthly amount to change. Edit a specific expense instead, or add a monthly one. Nothing changed.", error.message
    assert_expense registration, amount_cents: 15_000, cadence: "one_time", active: true
    assert_equal 1, @household.expense_items.where(stack_key: "non_discretionary").count
  end

  test "a zero total for a stack with only one-time items is a no-op" do
    registration = add_expense("Car registration", 15_000, "one_time")

    update_fixed_expenses("0")

    assert_expense registration, amount_cents: 15_000, cadence: "one_time", active: true
  end

  test "an empty stack still gets one monthly setup item" do
    update_fixed_expenses("2100")

    item = @household.expense_items.find_by!(stack_key: "non_discretionary")
    assert_equal "Fixed essentials", item.label
    assert_expense item, amount_cents: 210_000, cadence: "monthly", active: true
  end

  test "a paused recurring item comes back on its own schedule" do
    insurance = add_expense("Car insurance", 0, "annual", active: false)

    update_fixed_expenses("100")

    assert_expense insurance, amount_cents: 120_000, cadence: "annual", active: true
  end

  private

  def add_expense(label, amount_cents, cadence, stack_key: "non_discretionary", active: true)
    @household.expense_items.create!(label: label, stack_key: stack_key, amount_cents: amount_cents, cadence: cadence, active: active)
  end

  def update_fixed_expenses(value)
    HouseholdFinance::SetupUpdater.new(@household, fixed_expenses: value).call
  end

  def fixed_monthly_equivalent_cents
    @household.expense_items.where(stack_key: "non_discretionary", active: true).sum do |item|
      HouseholdFinance::Money.monthly_cents(item.amount_cents, item.cadence)
    end
  end

  def assert_expense(record, amount_cents:, cadence:, active:)
    record.reload
    assert_equal amount_cents, record.amount_cents, record.label
    assert_equal cadence, record.cadence, record.label
    assert_equal active, record.active, record.label
  end
end
