require "test_helper"

class YearForecastAnswerTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "talun-forecast-answer@example.invalid", clerk_id: "talun-forecast-answer")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    @today = Date.new(2026, 11, 21)
    @household.bills.create!(name: "Talun power", amount_cents: 8_000, due_on: "2026-01-28", repeat_months: 1)
    @household.bills.create!(name: "Talun water", amount_cents: 4_000, due_on: "2026-01-25", repeat_months: 1, estimate: true)
    @household.bills.create!(name: "Talun registration", amount_cents: 150_000, due_on: "2026-03-10", repeat_months: 12)
    @household.bills.create!(name: "Talun school fee", amount_cents: 20_000, due_on: "2027-01-05")
  end

  test "the next big bill is the largest due in the next 60 days, looking past December" do
    answer = answer("What's my next big bill?")
    assert_includes answer, "Your biggest bill due in the next 60 days is Talun school fee, $200, due January 5, 2027"
    assert_includes answer, "Nothing changed."

    answer = answer("What's my next big bill?", today: Date.new(2027, 1, 20))
    assert_includes answer, "Talun registration, $1,500, due March 10"
  end

  test "what is due this month lists every bill" do
    answer = answer("What's due this month?")
    assert_includes answer, "Due in November: Talun water, $40, due November 25 (estimated, must pay); Talun power, $80, due November 28 (must pay)."
  end

  test "a month asked about after it passed means the coming one, with its year" do
    answer = answer("What bills are due in January?")
    assert_includes answer, "Due in January 2027: Talun school fee, $200, due January 5, 2027 (must pay); Talun water"
    assert_includes answer, "Talun power, $80, due January 28, 2027"
    assert_includes answer("What's due in March?"), "Talun registration, $1,500, due March 10, 2027"
    assert_includes answer("What's due in December?"), "Due in December: Talun water"
  end

  test "a past one time bill not marked paid is asked about, and a paid one is gone" do
    repair = @household.bills.create!(name: "Talun repair", amount_cents: 69_000, due_on: "2026-09-22")
    assert_includes answer("What's due this month?"), "Past its date and not marked paid: Talun repair, $690, due September 22."
    repair.update!(paid_on: @today)
    assert_not_includes answer("What's due this month?"), "Talun repair"
  end

  test "the year answer words Rails facts without the technical rule" do
    forecast = { first_short_month: { label: "December", ending_cents: -78_000, reasons: [ "Talun repair" ], includes_estimates: true },
      status: "short", starting_note: "Starting from your cash balances on November 14.", starting_cash_cents: 320_000, months: [],
      estimate_reasons: [ "estimated pay for the rest of this month" ] }
    answer = answer("Will we make it through the year?", forecast: forecast)
    assert_equal "December is the first month that runs short: cash would end about $780 below zero. Costs that month include Talun repair. This rests on estimates: estimated pay for the rest of this month. Starting from your cash balances on November 14.", answer
    no_short = { first_short_month: nil, status: "no_short_month", starting_note: "Starting from your cash balances on November 14.", starting_cash_cents: 320_000,
      months: [ { label: "December", ending_cents: 170_000, includes_estimates: true } ], estimate_reasons: [ "debt payments that may already be paid this month" ] }
    assert_equal "No month runs short through December in this plan; December would end with about $1,700. This rests on estimates: debt payments that may already be paid this month. Starting from your cash balances on November 14.", answer("Will we make it through the year?", forecast: no_short)
    unknown = answer("Will we make it through December?", forecast: { status: "unknown", starting_cash_cents: nil, missing: [ "your monthly debt payments" ],
      starting_note: "Your cash balances are from September 30. Update them in My Money to see ending cash.", months: [] })
    assert_equal "I can’t tell yet whether you’ll make it through December. Your cash balances are from September 30. Update them in My Money to see ending cash. Still needed: your monthly debt payments.", unknown
  end

  test "worries, payment reports and bill triage are not forecast questions" do
    [ "We're short on rent this year, what do I do?", "Paid through December 15", "Paid $120 power, bills due scare me",
      "Which bill do I pay first before payday?", "I'm behind on bills due this month" ].each do |message|
      assert_not HouseholdFinance::YearForecastAnswer.question?(message), message
      assert_nil HouseholdFinance::YearForecastAnswer.new(@household, message, today: @today).call, message
    end
    %w[What's\ due\ in\ January? Will\ we\ make\ it\ through\ the\ year? Which\ month\ runs\ short?].each do |message|
      assert HouseholdFinance::YearForecastAnswer.question?(message), message
    end
  end

  test "Mia leaves a payment report to the spending report and reads the plan once" do
    coach = HouseholdFinance::MiaCoachAnswerer.new(@household, "Paid $120 power, bills due scare me", ensure_plan: false)
    assert_not_includes coach.support_answer.to_s, "Due in"
    assert_not_includes coach.call.to_s, "Due in"

    manager = HouseholdFinance::AnnualBudgetManager.new(@household)
    calls = 0
    manager.define_singleton_method(:read_only_plan_data) { calls += 1; super() }
    coach = HouseholdFinance::MiaCoachAnswerer.new(@household, "Will we make it through the year?", annual_budget_manager: manager, ensure_plan: false)
    first = coach.support_answer
    assert_match(/through December/, first)
    assert_equal first, coach.call
    assert_equal 1, calls
  end

  test "a purchase scenario goes to purchase analysis, not the plain year answer" do
    [ "Can I buy a $500 TV, and will we make it through the year?", "If we spend $900 on a trip, will we make it through December?",
      "Will we make it through the year if I purchase a new phone?" ].each do |message|
      assert_not HouseholdFinance::YearForecastAnswer.question?(message), message
      assert_nil HouseholdFinance::YearForecastAnswer.new(@household, message, forecast: { status: "no_short_month", months: [] }, today: @today).call, message
      coach = HouseholdFinance::MiaCoachAnswerer.new(@household, message, ensure_plan: false)
      assert_not_includes coach.support_answer.to_s, "No month runs short", message
    end
    [ "Can we get through December?", "Will we make it through the year?" ].each do |message|
      assert HouseholdFinance::YearForecastAnswer.question?(message), message
    end
  end

  test "a question about another year is not answered with this year's forecast" do
    this_year = { first_short_month: nil, status: "no_short_month", starting_note: "Starting from your cash balances on November 14.", starting_cash_cents: 320_000,
      months: [ { label: "December", ending_cents: 170_000 } ], estimate_reasons: [] }
    answer = answer("Will we make it through December 2027?", forecast: this_year)
    assert_not_includes answer, "$1,700"
    assert_includes answer, "only through December 2026"
    assert_includes answer, "Nothing changed."
    assert_includes answer("Will we make it through December 2026?", forecast: this_year), "December would end with about $1,700"
    assert_not_includes answer("Will we make it through the end of 2027?", forecast: this_year).to_s, "$1,700"
    assert_includes answer("Will we make it through the year with $2050 saved?", forecast: this_year), "December would end with about $1,700"
  end

  private

  def answer(message, today: @today, forecast: nil)
    HouseholdFinance::YearForecastAnswer.new(@household, message, forecast: forecast, today: today).call
  end
end
