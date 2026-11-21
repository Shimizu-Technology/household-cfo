require "test_helper"

# Debts with arrears, using the fictional Talun household: a car loan $1,500 behind and
# a store card that is current. All names and amounts are invented.
class HouseholdFinanceDebtArrearsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "talun_#{SecureRandom.hex(4)}", email: "talun-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @household.update!(name: "Talun household", primary_goal: "Get current on the car loan",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    @household.income_sources.create!(label: "Tasi's pay", source_type: "job", amount_cents: 520_000, cadence: "monthly")
    @household.expense_items.create!(label: "Rent and power", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    @household.accounts.create!(label: "Savings", account_type: "emergency_fund", balance_cents: 150_000)
    @car = @household.debts.create!(label: "Car loan", debt_type: "auto_loan", balance_cents: 980_000, minimum_payment_cents: 31_000,
      interest_rate_percent: 6.5, due_day: 15, past_due_cents: 150_000)
    @card = @household.debts.create!(label: "Store card", debt_type: "credit_card", balance_cents: 64_000, minimum_payment_cents: 3_500,
      interest_rate_percent: 29.99)
  end

  test "due day and past-due amount are optional and validated" do
    assert_nil @card.due_day
    assert_nil @card.past_due_cents, "a blank past-due amount stays unknown, never $0"
    refute @card.past_due?

    @card.past_due_cents = 0
    assert @card.valid?
    refute @card.past_due?, "$0 past due is caught up"

    [ 0, 32 ].each do |day|
      @card.due_day = day
      refute @card.valid?, "due day #{day} should be rejected"
    end
    @card.due_day = 31
    @card.past_due_cents = -1
    refute @card.valid?
  end

  test "the database rejects an impossible due day or a negative past-due amount" do
    [ { due_day: 32 }, { due_day: 0 }, { past_due_cents: -100 } ].each do |values|
      assert_raises(ActiveRecord::StatementInvalid, values.inspect) { Debt.transaction(requires_new: true) { @card.update_columns(values) } }
    end
    @card.update_columns(due_day: 1, past_due_cents: 0)
    assert_equal [ 1, 0 ], [ @card.reload.due_day, @card.past_due_cents ]
  end

  test "manual edits save, clear and keep both fields" do
    runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "22", past_due: "95.40" }, idempotency_key: "talun-card-1")
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]

    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, balance: "600" }, idempotency_key: "talun-card-2")
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ], "an unrelated edit keeps both"

    runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "", past_due: "" }, idempotency_key: "talun-card-3")
    assert_nil @card.reload.due_day
    assert_nil @card.past_due_cents, "clearing the field makes it unknown again, not $0"

    error = assert_raises(ArgumentError) do
      runner.run(operation_key: "debt.record.update", input: { debt_id: @card.id, due_day: "40" }, idempotency_key: "talun-card-4")
    end
    assert_match "1 to 31", error.message

    created = runner.run(operation_key: "debt.record.create", input: { label: "Clinic bill plan", debt_type: "medical", balance: "800", past_due: "0", due_day: "5" }, idempotency_key: "talun-clinic")
    assert_equal [ 5, 0 ], [ created.subject.due_day, created.subject.past_due_cents ]
  end

  test "an approved statement balance leaves the due day and past-due amount alone" do
    @car.update!(balance_cents: 900_000)
    assert_equal [ 15, 150_000 ], [ @car.reload.due_day, @car.past_due_cents ]
  end

  test "Home lists the past-due debt with what needs her" do
    dashboard = HouseholdFinance::DataPresenter.new(@household).dashboard
    past_due = dashboard.fetch(:action_center).fetch(:past_due_debts)

    assert_equal [ { id: @car.id, label: "Car loan", past_due_cents: 150_000, due_day: 15 } ], past_due
    debt = HouseholdFinance::DataPresenter.new(@household).debt_records.find { |record| record[:id] == @car.id }
    assert_equal 1_500.0, debt.fetch(:past_due)
    assert_equal 15, debt.fetch(:due_day)
    assert_nil HouseholdFinance::DataPresenter.new(@household).debt_records.find { |record| record[:id] == @card.id }.fetch(:past_due)
  end

  test "the debt plan catches up the past-due amount first, then the payoff order" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.", debt_order: "snowball").call

    assert_includes answer, "You are behind on Car loan $1,500 past due (payment due on the 15th)."
    assert_includes answer, "1. Catch up the $1,500 past due first: Car loan $1,500 past due (payment due on the 15th). 2. Protect essential bills"
    assert_includes answer, "Snowball: Store card first"
    # Hand check: $5,200 income - $3,000 essentials - $345 minimums = $1,855 surplus.
    # $1,855 - $1,500 catch-up = $355; the Store card cap is $640 - $35 = $605, so $355.
    assert_includes answer, "up to $355"
    assert_includes answer, "Snowball and avalanche apply to extra payments after the past-due amounts are caught up."
    assert_operator answer.index("You are behind"), :<, answer.index("Snowball:")
  end

  test "a catch-up larger than the surplus holds extra principal" do
    @car.update!(past_due_cents: 250_000)
    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.", debt_order: "avalanche").call

    assert_includes answer, "1. Catch up the $2,500 past due first"
    assert_includes answer, "3. Hold extra principal until the past-due amounts are caught up; this month's $1,855 surplus does not cover all of it."
    refute_includes answer, "up to $"
  end

  test "what should I pay first answers with the past-due amount, then the program's order" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call

    assert answer.start_with?("Catch up what you are behind on first: Car loan $1,500 past due (payment due on the 15th)."), answer
    assert_includes answer, "keep every other minimum current"
    assert_includes answer, "After you are caught up, extra payments go to Store card first: it is both the smallest balance (snowball) and the highest APR (avalanche)."

    @household.debts.create!(label: "Clinic plan", debt_type: "medical", balance_cents: 30_000, minimum_payment_cents: 2_500, interest_rate_percent: 0)
    split = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call
    assert_includes split, "After you are caught up, extra payments follow your payoff order: avalanche (highest APR first) starts with Store card, or snowball (smallest balance first) starts with Clinic plan."
    assert_includes answer, "No payment is made automatically."
  end

  test "with nothing past due the bill answer is unchanged and a blank amount is not treated as behind" do
    @car.update!(past_due_cents: nil)
    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "What should I pay first?").call
    refute_includes answer, "past due"
    assert_includes answer, "Start with the bill that protects the household baseline first."
    assert_empty HouseholdFinance::DebtArrears.new(@household).debts
  end

  test "Mia's context gives each debt's due day and past-due amount, unknown kept blank" do
    debts = HouseholdFinance::MiaContextBuilder.new(@household).send(:debt_context)
    records = debts.fetch(:records).index_by { |record| record[:label] }

    assert_equal [ 15, "$1,500" ], records.fetch("Car loan").values_at(:due_day, :past_due)
    assert_nil records.fetch("Store card")[:past_due]
    assert_includes debts.fetch(:unavailable_fields), "due_date"
    assert_equal "Car loan", debts.dig(:past_due, :debts, 0, :label)
    assert_match "comes first", debts.dig(:past_due, :rule)
  end

  test "Mia prepares a past-due and due-day update that changes nothing until she applies it" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: manager,
      raw_input: "model resolved debt command", command: { type: "update_debt", debt_id: @card.id, past_due: "95.40", due_day: "22nd" }).call

    assert_includes result.proposal.summary, "$95.40 past due"
    assert_includes result.proposal.summary, "payment due on the 22nd"
    assert_nil @card.reload.past_due_cents

    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    draft = result.proposal.create_draft!(
      source_chat_message: session.chat_messages.create!(role: "user", content: "I'm $95.40 behind on the Store card, due on the 22nd"),
      assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change")
    )
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
    assert_equal({ label: "Past due", before: "Not entered", after: "$95.40" }, review.find { |field| field[:label] == "Past due" })
    assert_equal({ label: "Payment due day", before: "Not entered", after: "The 22nd of each month" }, review.find { |field| field[:label] == "Payment due day" })

    applied = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal [ 22, 9_540 ], [ @card.reload.due_day, @card.past_due_cents ]
  end
end
