module Demo
  class HouseholdData
    BASE_MONTHLY_INCOME = 8_250
    RAISED_MONTHLY_INCOME = 8_500
    RECURRING_INCOME_CHANGE_MONTH = 8
    YEAR_END_BONUS = 1_000
    CATEGORY_PLAN = 6_925
    MONTHLY_DEBT_MINIMUMS = 920
    PROTECTED_LIQUID = 25_090
    TARGET_RUNWAY_MONTHS = 6
    CHECKING_BALANCE = 6_840
    EMERGENCY_FUND_BALANCE = 18_250
    CREDIT_CARD_BALANCE = 7_350
    AUTO_LOAN_BALANCE = 11_900
    RETIREMENT_BALANCE = 136_960
    BUSINESS_INCOME = 1_200
    RENTAL_PASSIVE_INCOME = 1_850

    def self.persona
      ::Mia::Persona.default
    end

    def self.profile
      facts = financial_facts
      {
        household: {
          name: "Household CFO Demo Family",
          stage: "Cohort preview",
          location: "Guam",
          primary_goal: "Build a clear monthly money rhythm before making a major career move"
        },
        coach: {
          name: persona.name,
          role: persona.role,
          voice: persona.voice_summary
        },
        members: [
          { name: "Ariana", role: "Primary household CFO", age_range: "30s" },
          { name: "Marcus", role: "Partner", age_range: "30s" }
        ],
        priorities: [
          "Know what is safe to spend",
          "Protect the emergency fund",
          "Plan a founder transition",
          "Reduce debt without losing momentum"
        ],
        completeness: 68,
        uploads: [
          { label: "Upload spreadsheet", kind: "spreadsheet", status: "Optional starter import", accepts: ".xlsx, .xls, .csv" },
          { label: "Upload statement", kind: "statement", status: "Bank or credit card PDF/CSV", accepts: ".pdf, .csv, .png, .jpg" },
          { label: "Upload pay stub", kind: "paystub", status: "Photo or PDF when ready", accepts: ".pdf, .png, .jpg" }
        ],
        sections: [
          {
            label: "Income",
            summary: "Base pay, rental income, bonuses, and business revenue.",
            items: [
              { label: "Primary income", amount: facts.fetch(:monthly_income) - 3_050 },
              { label: "Rental/passive income", amount: RENTAL_PASSIVE_INCOME },
              { label: "Business income", amount: BUSINESS_INCOME }
            ]
          },
          {
            label: "Expenses",
            summary: "Bills, choices, and the things life always seems to throw at you.",
            items: [
              { label: "Housing", amount: 2100 },
              { label: "Fixed bills", amount: 2525 },
              { label: "Food, gas, discretionary", amount: 1380 },
              { label: "Expected sinking funds", amount: 560 },
              { label: "Unexpected sinking fund", amount: 360 }
            ]
          },
          {
            label: "Savings & Debt",
            summary: "Runway, credit cards, loans, and the next stability target.",
            items: [
              { label: "Emergency fund", amount: EMERGENCY_FUND_BALANCE },
              { label: "Credit card debt", amount: -CREDIT_CARD_BALANCE },
              { label: "Auto loan", amount: -AUTO_LOAN_BALANCE }
            ]
          }
        ]
      }
    end

    def self.dashboard
      facts = financial_facts
      {
        summary: {
          monthly_income: facts.fetch(:monthly_income),
          fixed_expenses: 4625,
          flexible_spend: 1380,
          debt_payments: facts.fetch(:debt_minimums),
          baseline_surplus: facts.fetch(:baseline_surplus),
          monthly_surplus_rate_percent: facts.fetch(:monthly_surplus_rate_percent),
          runway_months: facts.fetch(:runway_months),
          next_safe_to_spend_amount: facts.fetch(:safe_to_spend),
          readiness_tone: facts.fetch(:readiness_tone),
          readiness_label: facts.fetch(:readiness_label)
        },
        budget_basis: facts.slice(:monthly_income, :category_plan, :debt_minimums, :total_monthly_outflow, :baseline_surplus),
        action_center: {
          transaction_review_count: 0,
          mia_action_review_count: 0,
          total_review_count: 0,
          current_month_label: Date.current.strftime("%B"),
          current_month_index: Date.current.month - 1,
          current_year: Date.current.year
        },
        coach_read: {
          title: "Close the remaining runway gap.",
          body: "Your monthly cash flow is holding, but the household still needs more protected runway. Keep expected expenses funded and direct planned surplus toward the runway target before expanding wants."
        },
        readiness_path: {
          current_runway_months: facts.fetch(:runway_months),
          target_runway_months: facts.fetch(:target_runway_months),
          protected_liquid_amount: facts.fetch(:protected_liquid),
          monthly_surplus: facts.fetch(:baseline_surplus),
          yellow: {
            tone: "yellow",
            runway_months: 3,
            protected_liquid_target: facts.fetch(:yellow_runway_target),
            protected_liquid_gap: facts.fetch(:yellow_runway_gap),
            cash_flow_requirement: "Nonnegative monthly cash flow",
            reached: true
          },
          green: {
            tone: "green",
            runway_months: 6,
            protected_liquid_target: facts.fetch(:green_runway_target),
            protected_liquid_gap: facts.fetch(:green_runway_gap),
            cash_flow_requirement: "Positive monthly cash flow",
            reached: false
          }
        },
        accounts: [
          { name: "Checking", type: "cash", balance: CHECKING_BALANCE },
          { name: "Emergency Fund", type: "savings", balance: EMERGENCY_FUND_BALANCE },
          { name: "Credit Card", type: "debt", balance: -CREDIT_CARD_BALANCE },
          { name: "Auto Loan", type: "debt", balance: -AUTO_LOAN_BALANCE }
        ],
        alerts: [
          { tone: "green", title: "Bills covered", body: "All fixed expenses are funded through the next pay cycle." },
          { tone: "yellow", title: "Debt focus", body: "Card payoff matters, but unplanned wants should stay within the #{money(facts.fetch(:safe_to_spend))} safe-to-spend guardrail this month." },
          {
            tone: "blue",
            title: "Runway",
            body: "You are #{(facts.fetch(:target_runway_months) - facts.fetch(:runway_months)).round(1)} months away from the six-month founder transition target."
          }
        ],
        next_steps: [
          "Keep this month’s flexible spending under $1,380.",
          "Direct this month’s #{money(facts.fetch(:baseline_surplus))} baseline surplus toward protected runway before extra debt payments.",
          "Add one recurring business retainer before changing job income."
        ]
      }
    end

    def self.budget
      facts = financial_facts
      {
        framework: "Expense Stack",
        intro: "Most budgets collapse life into bills versus fun. Household CFO separates the expenses that surprise you before they turn into emergencies.",
        monthly_income: facts.fetch(:monthly_income),
        total_monthly_outflow: facts.fetch(:total_monthly_outflow),
        baseline_surplus: facts.fetch(:baseline_surplus),
        stacks: [
          {
            label: "Non-discretionary",
            color: "green",
            amount: 4625,
            description: "Fixed, non-negotiable monthly obligations.",
            examples: [ "Mortgage/rent", "utilities", "insurance", "childcare" ]
          },
          {
            label: "Discretionary",
            color: "yellow",
            amount: 1380,
            description: "Choices that still matter, but can be shaped.",
            examples: [ "groceries", "coffee", "eating out", "subscriptions" ]
          },
          {
            label: "Sinking Fund — Expected",
            color: "gold",
            amount: 560,
            description: "Known irregular expenses that should stop feeling like surprises.",
            examples: [ "car registration", "back to school", "holidays" ]
          },
          {
            label: "Sinking Fund — Unexpected",
            color: "red",
            amount: 360,
            description: "Life-happens money for repairs, medical, and family support.",
            examples: [ "car repair", "clinic visit", "appliance replacement" ]
          }
        ],
        custom_categories_note: "Defaults are a starting point. Users should be able to rename categories into the language of their household.",
        annual_plan: annual_plan
      }
    end

    def self.annual_plan(on: Date.current)
      year = on.year
      months = (1..12).map do |month|
        starts_on = Date.new(year, month, 1)
        {
          id: month,
          label: starts_on.strftime("%b"),
          starts_on: starts_on.iso8601,
          ends_on: starts_on.end_of_month.iso8601,
          status: "open"
        }
      end
      rows = [
        demo_budget_row(1, "Fixed essentials", "non_discretionary", "Non-discretionary", 4_625, months),
        demo_budget_row(2, "Flexible spending", "discretionary", "Discretionary", 1_380, months),
        demo_budget_row(3, "Expected sinking funds", "sinking_expected", "Sinking Fund — Expected", 560, months, december_amount: 2_560),
        demo_budget_row(4, "Unexpected sinking fund", "sinking_unexpected", "Sinking Fund — Unexpected", 360, months)
      ]
      monthly_debt_minimums = MONTHLY_DEBT_MINIMUMS
      income = months.to_h { |month| [ month[:id], recurring_monthly_income(month: month[:id]) ] }
      income[12] += YEAR_END_BONUS
      outlook_months = months.map do |month|
        category_plan = rows.sum { |row| row[:months][month[:id] - 1][:planned] }
        planned = category_plan + monthly_debt_minimums
        expected = rows[2][:months][month[:id] - 1][:planned]
        {
          period_id: month[:id],
          label: month[:label],
          starts_on: month[:starts_on],
          income: income.fetch(month[:id]),
          category_plan: category_plan,
          debt_minimums: monthly_debt_minimums,
          planned_outflow: planned,
          baseline_surplus: income.fetch(month[:id]) - planned,
          expected_irregular: expected,
          expected_contributors: [ { name: "Expected sinking funds", amount: expected } ]
        }
      end
      december = outlook_months.last.merge(amount_above_typical: 2_000)

      {
        year: year,
        months: months,
        rows: rows,
        monthly_debt_minimums: monthly_debt_minimums,
        monthly_income: income,
        income_sources: [
          {
            id: 1,
            label: "Primary income",
            source_type: "job",
            base_amount: BASE_MONTHLY_INCOME,
            base_cadence: "monthly",
            schedule_entries: [
              { id: 1, entry_type: "recurring_change", label: nil, amount: RAISED_MONTHLY_INCOME, cadence: "monthly", effective_on: Date.new(year, RECURRING_INCOME_CHANGE_MONTH, 1).iso8601 },
              { id: 2, entry_type: "one_time", label: "Year-end bonus", amount: YEAR_END_BONUS, cadence: "one_time", effective_on: Date.new(year, 12, 1).iso8601 }
            ]
          }
        ],
        annual_outlook: {
          typical_monthly_outflow: CATEGORY_PLAN + monthly_debt_minimums,
          months: outlook_months,
          upcoming_spikes: [ december ],
          next_irregular_month: outlook_months.find { |month| Date.iso8601(month[:starts_on]) >= on.beginning_of_month }
        },
        pending_transaction_drafts: [],
        pending_mia_action_drafts: [],
        recent_transactions: [],
        archived_categories: []
      }
    end

    def self.financial_facts(on: Date.current)
      monthly_income = recurring_monthly_income(month: on.month)
      result = HouseholdFinance::ReadinessCalculator.new(
        monthly_income_cents: HouseholdFinance::Money.cents(monthly_income),
        category_outflow_cents: HouseholdFinance::Money.cents(CATEGORY_PLAN),
        debt_minimums_cents: HouseholdFinance::Money.cents(MONTHLY_DEBT_MINIMUMS),
        protected_liquid_cents: HouseholdFinance::Money.cents(PROTECTED_LIQUID),
        target_runway_months: TARGET_RUNWAY_MONTHS
      ).call

      {
        monthly_income: monthly_income,
        category_plan: CATEGORY_PLAN,
        debt_minimums: MONTHLY_DEBT_MINIMUMS,
        total_monthly_outflow: dollars(result.fetch(:total_outflow_cents)),
        baseline_surplus: dollars(result.fetch(:baseline_surplus_cents)),
        monthly_surplus_rate_percent: (result.fetch(:baseline_surplus_cents) / HouseholdFinance::Money.cents(monthly_income).to_f * 100).round,
        protected_liquid: PROTECTED_LIQUID,
        runway_months: result.fetch(:runway_months),
        target_runway_months: result.fetch(:target_runway_months),
        readiness_tone: result.fetch(:readiness_tone),
        readiness_label: result.fetch(:readiness_label),
        safe_to_spend: dollars(result.fetch(:safe_to_spend_cents)),
        yellow_runway_target: dollars(result.fetch(:yellow_runway_target_cents)),
        yellow_runway_gap: dollars(result.fetch(:yellow_runway_gap_cents)),
        green_runway_target: dollars(result.fetch(:green_runway_target_cents)),
        green_runway_gap: dollars(result.fetch(:green_runway_gap_cents))
      }
    end

    def self.recurring_monthly_income(month: Date.current.month)
      month >= RECURRING_INCOME_CHANGE_MONTH ? RAISED_MONTHLY_INCOME : BASE_MONTHLY_INCOME
    end

    def self.mia_context
      {
        basis: "approved demo household numbers",
        financial_facts: financial_facts,
        transaction_ledger: { available: false, confirmed_transaction_count: 0 },
        boundaries: [
          "Category plan excludes debt minimums.",
          "Safe-to-spend is a monthly decision guardrail, not an account balance.",
          "The exact impact of a hypothetical purchase depends on its funding account and category.",
          "An empty preview ledger is missing data, not proof of zero spending."
        ]
      }
    end

    def self.dollars(cents)
      HouseholdFinance::Money.dollars(cents)
    end

    def self.money(value)
      ActiveSupport::NumberHelper.number_to_currency(value, precision: value.to_f % 1 == 0 ? 0 : 2)
    end

    def self.demo_budget_row(id, name, stack_key, stack_label, monthly_amount, months, december_amount: monthly_amount)
      cells = months.map do |month|
        planned = month[:id] == 12 ? december_amount : monthly_amount
        { period_id: month[:id], allocation_id: id * 100 + month[:id], planned: planned, actual: 0, remaining: planned }
      end
      {
        id: id,
        name: name,
        stack_key: stack_key,
        stack_label: stack_label,
        active: true,
        months: cells,
        planned_total: cells.sum { |cell| cell[:planned] },
        actual_total: 0
      }
    end

    def self.wealth
      facts = financial_facts
      total_debt = CREDIT_CARD_BALANCE + AUTO_LOAN_BALANCE
      net_worth = PROTECTED_LIQUID + RETIREMENT_BALANCE - total_debt
      {
        summary: {
          net_worth: net_worth,
          liquid_net_worth: PROTECTED_LIQUID - CREDIT_CARD_BALANCE,
          ten_year_surplus_capacity: facts.fetch(:baseline_surplus) * 12 * 10,
          monthly_surplus_available: facts.fetch(:baseline_surplus)
        },
        milestones: [
          { kind: "progress", label: "Six-month runway", current: facts.fetch(:runway_months), target: facts.fetch(:target_runway_months), unit: "months", status: facts.fetch(:readiness_tone) },
          { kind: "debt_remaining", label: "Credit card balance", current: CREDIT_CARD_BALANCE, target: 0, unit: "dollars", status: "yellow" },
          { kind: "progress", label: "Protected runway", current: PROTECTED_LIQUID, target: facts.fetch(:green_runway_target), unit: "dollars", status: facts.fetch(:readiness_tone) }
        ],
        guidance: "Wealth here is not about looking rich. It is about buying back options, lowering panic, and making the next right move visible."
      }
    end

    def self.optionality
      facts = financial_facts
      required_business_income = [ facts.fetch(:total_monthly_outflow) - RENTAL_PASSIVE_INCOME, 0 ].max
      monthly_gap = [ required_business_income - BUSINESS_INCOME, 0 ].max
      {
        scenario: "Founder transition",
        question: "What would it take to safely move from stable employment into the business full-time?",
        target_runway_months: 6,
        current_runway_months: facts.fetch(:runway_months),
        monthly_gap: monthly_gap,
        choices: [
          {
            label: "Stay the course",
            fit_label: "Best fit now",
            fit_tone: "green",
            upside: "Lowest stress and keeps debt payoff consistent.",
            tradeoff: "Slower path to full-time founder mode."
          },
          {
            label: "Hybrid transition",
            fit_label: "Plan carefully",
            fit_tone: "yellow",
            upside: "Protects household stability while opening 15 focused hours per week.",
            tradeoff: "Requires tighter discretionary spending for 90 days."
          },
          {
            label: "Leap now",
            fit_label: "Not ready yet",
            fit_tone: "red",
            upside: "Maximum business focus immediately.",
            tradeoff: "Runway is short unless one new retainer is signed first."
          }
        ],
        levers: [
          { label: "Income continuing after transition", amount: RENTAL_PASSIVE_INCOME },
          { label: "Business needs to pay", amount: required_business_income },
          { label: "Current business income", amount: BUSINESS_INCOME },
          { label: "Six-month runway gap", amount: facts.fetch(:green_runway_gap) }
        ]
      }
    end

    def self.cfo_filter
      facts = financial_facts
      runway_met = facts.fetch(:green_runway_gap).zero?
      baseline_positive = facts.fetch(:baseline_surplus).positive?
      {
        framework: "CFO Filter",
        prompt: "Before money leaves the household, ask whether this spend protects stability, creates optionality, or moves the dream forward.",
        decisions: [
          {
            item: "Non-essential purchase",
            amount: facts.fetch(:safe_to_spend),
            recommendation: facts.fetch(:safe_to_spend).positive? ? "Pause" : "Wait",
            reason: "Only approve wants that fit inside true surplus after bills, sinking funds, debt minimums, and confirmed activity."
          },
          {
            item: "Extra debt payment",
            amount: runway_met && baseline_positive ? facts.fetch(:safe_to_spend) : 0,
            recommendation: runway_met && baseline_positive ? "Approve" : "Wait",
            reason: runway_met ? "Debt payoff improves breathing room after the runway target is protected." : "Protect the six-month runway target before adding an extra debt payment."
          },
          {
            item: "Runway transfer",
            amount: [ facts.fetch(:baseline_surplus), 0 ].max,
            recommendation: runway_met ? "Optional" : (baseline_positive ? "Approve" : "Wait"),
            reason: runway_met ? "The runway target is protected; additional transfers are optional after essentials stay covered." : "Runway buys options and lowers panic."
          }
        ],
        targets: [
          { label: "Protected runway", current: PROTECTED_LIQUID, target: facts.fetch(:green_runway_target) },
          { label: "Debt payoff", current: CREDIT_CARD_BALANCE + AUTO_LOAN_BALANCE, target: 0 },
          { label: "Monthly business revenue", current: BUSINESS_INCOME, target: [ facts.fetch(:total_monthly_outflow) - RENTAL_PASSIVE_INCOME, 0 ].max }
        ],
        priority_stack: [ "Protect the roof", "Protect food/gas", "Protect runway", "Attack high-interest debt", "Fund the dream with evidence" ]
      }
    end

    def self.mia_messages
      facts = financial_facts
      {
        messages: [
          {
            role: "assistant",
            author: "Mia",
            content: "Håfa Adai. I loaded your profile, your Expense Stack, and your runway so we can look at the whole picture, not one scary number by itself."
          },
          {
            role: "user",
            author: "Ariana",
            content: "Can I start moving toward the business full-time?"
          },
          {
            role: "assistant",
            author: "Mia",
            content: "You can move toward it, but the clean path is hybrid first. Your runway is strong enough to make a measured CFO move, not a leap-of-faith move. One next move: close the #{money(facts.fetch(:green_runway_gap))} six-month runway gap before you cut stable income."
          }
        ],
        oldest_message_id: nil,
        older_message_count: 0,
        has_older_messages: false,
        quick_prompts: [
          "Why is my readiness Yellow?",
          "Can I leave my job?",
          "Emergency fund or debt first?",
          "What should I do with a bonus?"
        ],
        disclaimer: persona.disclaimer
      }
    end
  end
end
