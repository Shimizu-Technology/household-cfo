module HouseholdFinance
  class DataPresenter
    QUICK_PROMPTS = [
      "Can I buy the purse?",
      "Why is my baseline yellow?",
      "Emergency fund or debt first?",
      "Can I leave my job?"
    ].freeze

    def initialize(household, user: nil)
      @household = household
      @user = user
      @snapshot_builder = SnapshotBuilder.new(household)
      @snapshot = @snapshot_builder.call
    end

    def app_data
      {
        workspace: workspace,
        profile: profile,
        dashboard: dashboard,
        budget: budget,
        wealth: wealth,
        optionality: optionality,
        cfoFilter: cfo_filter,
        mia: mia
      }
    end

    def workspace
      {
        mode: "real",
        household_id: household.id,
        setup_complete: snapshot.fetch(:profile_completeness) >= 70,
        setup_values: setup_values
      }
    end

    def profile
      {
        household: {
          name: household.name,
          stage: household.stage.presence || "First cohort",
          location: household.location.presence || "Guam",
          primary_goal: household.primary_goal.presence || "Build a clear monthly money rhythm."
        },
        coach: {
          name: "Mia",
          role: "Money Interactive Assistant",
          voice: "direct, warm, culturally grounded, CBT-informed"
        },
        members: members,
        priorities: priorities,
        completeness: snapshot.fetch(:profile_completeness),
        uploads: uploads,
        sections: profile_sections
      }
    end

    def dashboard
      {
        summary: {
          monthly_income: dollars(snapshot.fetch(:monthly_income_cents)),
          fixed_expenses: dollars(snapshot.fetch(:stack_totals_cents).fetch("non_discretionary")),
          flexible_spend: dollars(snapshot.fetch(:stack_totals_cents).fetch("discretionary")),
          debt_payments: dollars(snapshot.fetch(:debt_payments_cents)),
          savings_rate_percent: savings_rate_percent,
          runway_months: snapshot.fetch(:runway_months),
          next_safe_to_spend_amount: dollars(snapshot.fetch(:safe_to_spend_cents)),
          readiness_label: snapshot.fetch(:readiness_label)
        },
        accounts: account_rows,
        alerts: alerts,
        next_steps: next_steps
      }
    end

    def budget
      {
        framework: "Expense Stack",
        intro: "Most budgets collapse life into bills versus fun. Household CFO separates the expenses that surprise you before they turn into emergencies.",
        monthly_income: dollars(snapshot.fetch(:monthly_income_cents)),
        total_monthly_outflow: dollars(snapshot.fetch(:total_outflow_cents)),
        baseline_surplus: dollars(snapshot.fetch(:baseline_surplus_cents)),
        stacks: snapshot_builder.budget_stacks,
        custom_categories_note: "Rename these into the language of your household. The stack matters more than perfect accounting labels."
      }
    end

    def wealth
      {
        summary: {
          net_worth: dollars(snapshot.fetch(:net_worth_cents)),
          liquid_net_worth: dollars(snapshot.fetch(:liquid_assets_cents) - snapshot.fetch(:total_debt_cents)),
          retirement_projection: dollars(retirement_projection_cents),
          monthly_wealth_building: dollars(monthly_wealth_building_cents)
        },
        milestones: milestones,
        guidance: "Wealth here is not about looking rich. It is about buying back options, lowering panic, and making the next right move visible."
      }
    end

    def optionality
      runway_target = target_runway_months
      monthly_need_cents = [ snapshot.fetch(:total_outflow_cents), 0 ].max
      target_cash_cents = (monthly_need_cents * runway_target).round
      runway_gap_cents = [ target_cash_cents - snapshot.fetch(:liquid_assets_cents), 0 ].max
      business_income_cents = monthly_business_income_cents
      required_business_cents = [ monthly_need_cents - stable_income_cents, 0 ].max

      {
        scenario: transition_goal&.label || "Founder transition",
        question: household.primary_goal.presence || "What would it take to safely make the next move?",
        target_runway_months: runway_target,
        current_runway_months: snapshot.fetch(:runway_months),
        monthly_gap: dollars([ required_business_cents - business_income_cents, 0 ].max),
        choices: optionality_choices(runway_gap_cents),
        levers: [
          { label: "Business needs to pay", amount: dollars(required_business_cents) },
          { label: "Current business income", amount: dollars(business_income_cents) },
          { label: "Runway gap", amount: dollars(runway_gap_cents) }
        ]
      }
    end

    def cfo_filter
      {
        framework: "CFO Filter",
        prompt: "Before money leaves the household, ask whether this spend protects stability, creates optionality, or moves the dream forward.",
        decisions: decisions,
        targets: targets,
        priority_stack: [ "Protect the roof", "Protect food/gas", "Protect runway", "Attack high-interest debt", "Fund the dream with evidence" ]
      }
    end

    def mia
      {
        messages: chat_messages,
        quick_prompts: QUICK_PROMPTS,
        disclaimer: "Mia is a coaching and education tool powered by VERA. She does not replace legal, tax, investment, or financial advice."
      }
    end

    def setup_values
      {
        household_name: household.name,
        primary_goal: household.primary_goal.to_s,
        primary_income: dollars(income_by_type("job")),
        business_income: dollars(income_by_type("business")),
        fixed_expenses: dollars(expenses_by_stack("non_discretionary")),
        flexible_spend: dollars(expenses_by_stack("discretionary")),
        expected_sinking_fund: dollars(expenses_by_stack("sinking_expected")),
        unexpected_sinking_fund: dollars(expenses_by_stack("sinking_unexpected")),
        emergency_fund: dollars(account_by_type("emergency_fund")),
        other_assets: dollars(non_emergency_assets_cents),
        credit_card_debt: dollars(debt_by_type("credit_card")),
        debt_payment: dollars(debt_payments_by_type("credit_card")),
        target_runway_months: target_runway_months
      }
    end

    private

    attr_reader :household, :user, :snapshot_builder, :snapshot

    def members
      household.household_memberships.includes(:user).map do |membership|
        {
          name: membership.user.full_name,
          role: membership.role.titleize,
          age_range: ""
        }
      end.presence || [ { name: user&.full_name || "You", role: "Primary household CFO", age_range: "" } ]
    end

    def priorities
      [
        "Know what is safe to spend",
        "Protect the emergency fund",
        "Plan the next big move",
        "Reduce debt without losing momentum"
      ]
    end

    def uploads
      [
        { label: "Upload spreadsheet", kind: "spreadsheet", status: "Coming after privacy/OCR scope", accepts: ".xlsx, .xls, .csv" },
        { label: "Upload statement", kind: "statement", status: "Coming after privacy/OCR scope", accepts: ".pdf, .csv, .png, .jpg" },
        { label: "Upload pay stub", kind: "paystub", status: "Coming after privacy/OCR scope", accepts: ".pdf, .png, .jpg" }
      ]
    end

    def profile_sections
      [
        {
          label: "Income",
          summary: "Base pay, business income, rental income, bonuses, and other monthly money coming in.",
          items: household.income_sources.where(active: true).order(:source_type, :label).map { |income| { label: income.label, amount: dollars(Money.monthly_cents(income.amount_cents, income.cadence)) } }
        },
        {
          label: "Expenses",
          summary: "Bills, choices, and the things life always seems to throw at you.",
          items: household.expense_items.where(active: true).order(:stack_key, :label).map { |expense| { label: expense.label, amount: dollars(Money.monthly_cents(expense.amount_cents, expense.cadence)) } }
        },
        {
          label: "Savings & Debt",
          summary: "Runway, cash, credit cards, loans, and the next stability target.",
          items: savings_and_debt_items
        }
      ]
    end

    def savings_and_debt_items
      account_items = household.accounts.order(:account_type, :label).map { |account| { label: account.label, amount: dollars(account.balance_cents) } }
      debt_items = household.debts.order(:debt_type, :label).map { |debt| { label: debt.label, amount: -dollars(debt.balance_cents) } }
      account_items + debt_items
    end

    def savings_rate_percent
      income = snapshot.fetch(:monthly_income_cents)
      return 0 if income <= 0

      ([ snapshot.fetch(:baseline_surplus_cents), 0 ].max / income.to_f * 100).round
    end

    def account_rows
      household.accounts.order(:account_type, :label).map do |account|
        { name: account.label, type: account.account_type, balance: dollars(account.balance_cents) }
      end + household.debts.order(:debt_type, :label).map do |debt|
        { name: debt.label, type: "debt", balance: -dollars(debt.balance_cents) }
      end
    end

    def alerts
      if snapshot.fetch(:monthly_income_cents).zero? && snapshot.fetch(:total_outflow_cents).zero?
        return [
          { tone: "yellow", title: "Start with the basics", body: "Add monthly income, fixed bills, emergency fund, and debt so Mia can read your real household picture." }
        ]
      end

      [
        { tone: snapshot.fetch(:readiness_tone), title: "Readiness", body: snapshot.fetch(:readiness_label) },
        { tone: snapshot.fetch(:baseline_surplus_cents).positive? ? "green" : "red", title: "Baseline", body: baseline_body },
        { tone: debt_tone, title: "Debt focus", body: debt_body }
      ]
    end

    def baseline_body
      surplus = dollars(snapshot.fetch(:baseline_surplus_cents))
      return "Your baseline has #{ActiveSupport::NumberHelper.number_to_currency(surplus, precision: 0)} left after planned outflow." if surplus.positive?

      "Your planned outflow is above income. Pause extras and rebuild the baseline before adding new commitments."
    end

    def debt_tone
      snapshot.fetch(:total_debt_cents).positive? ? "yellow" : "green"
    end

    def debt_body
      debt = dollars(snapshot.fetch(:total_debt_cents))
      return "No debt entered yet. Add debts if you want Mia to pressure-test payoff decisions." if debt.zero?

      "You have #{ActiveSupport::NumberHelper.number_to_currency(debt, precision: 0)} in debt entered. Keep minimums protected before funding wants."
    end

    def next_steps
      steps = []
      steps << "Add income and Expense Stack numbers." if snapshot.fetch(:monthly_income_cents).zero? || snapshot.fetch(:total_expenses_cents).zero?
      steps << "Protect fixed bills and minimum debt payments first."
      steps << (snapshot.fetch(:safe_to_spend_cents).positive? ? "Keep wants under #{ActiveSupport::NumberHelper.number_to_currency(dollars(snapshot.fetch(:safe_to_spend_cents)), precision: 0)} until the next check-in." : "Pause new wants until baseline surplus is positive.")
      steps << "Ask Mia to pressure-test one decision before money leaves the household."
      steps.first(3)
    end

    def retirement_projection_cents
      retirement_accounts = household.accounts.select { |account| account.account_type == "retirement" }.sum(&:balance_cents)
      retirement_accounts + (monthly_wealth_building_cents * 12 * 10)
    end

    def monthly_wealth_building_cents
      [ snapshot.fetch(:baseline_surplus_cents), 0 ].max
    end

    def milestones
      runway_target = target_runway_months
      debt_total = dollars(snapshot.fetch(:total_debt_cents))
      [
        { label: "Runway target", current: snapshot.fetch(:runway_months), target: runway_target, unit: "months", status: snapshot.fetch(:readiness_tone) },
        { label: "Debt entered", current: debt_total.zero? ? 1 : 0, target: debt_total.zero? ? 1 : debt_total, unit: debt_total.zero? ? "clear" : "dollars to payoff", status: debt_total.zero? ? "green" : "yellow" },
        { label: "Emergency fund", current: dollars(account_by_type("emergency_fund")), target: dollars(snapshot.fetch(:total_outflow_cents) * runway_target), unit: "dollars", status: snapshot.fetch(:runway_months) >= runway_target ? "green" : "yellow" }
      ]
    end

    def transition_goal
      household.goals.where(goal_type: "transition").order(:priority).first
    end

    def target_runway_months
      goal = household.goals.where(goal_type: "runway").order(:priority).first
      (goal&.target_months || 6).to_f
    end

    def stable_income_cents
      household.income_sources.where(active: true).reject { |income| income.source_type == "business" }.sum { |income| Money.monthly_cents(income.amount_cents, income.cadence) }
    end

    def monthly_business_income_cents
      income_by_type("business")
    end

    def optionality_choices(runway_gap_cents)
      runway = snapshot.fetch(:runway_months)
      surplus_positive = snapshot.fetch(:baseline_surplus_cents).positive?
      [
        {
          label: "Stay the course",
          readiness_score: surplus_positive ? 78 : 55,
          upside: "Lowest stress and keeps the household baseline protected.",
          tradeoff: "Slower path to the dream move."
        },
        {
          label: "Hybrid transition",
          readiness_score: [ (runway / target_runway_months * 100).round, 95 ].min,
          upside: "Creates room for the dream while keeping stable income in the picture.",
          tradeoff: "Requires cleaner limits on discretionary spending."
        },
        {
          label: "Leap now",
          readiness_score: runway_gap_cents.zero? && surplus_positive ? 72 : 42,
          upside: "Maximum focus immediately.",
          tradeoff: runway_gap_cents.zero? ? "Still needs a written runway plan." : "Runway gap should close before cutting stable income."
        }
      ]
    end

    def decisions
      safe = dollars(snapshot.fetch(:safe_to_spend_cents))
      [
        {
          item: "Non-essential purchase",
          amount: safe.positive? ? safe : 100,
          recommendation: safe.positive? ? "Pause" : "Wait",
          reason: safe.positive? ? "Only approve wants that fit inside true surplus after bills, sinking funds, and debt minimums." : "Baseline is not ready for wants yet. Protect essentials first."
        },
        {
          item: "Extra debt payment",
          amount: [ safe, 250 ].max,
          recommendation: snapshot.fetch(:total_debt_cents).positive? && snapshot.fetch(:baseline_surplus_cents).positive? ? "Approve" : "Wait",
          reason: snapshot.fetch(:total_debt_cents).positive? ? "Debt payoff helps breathing room, but only after fixed bills and runway are protected." : "No debt entered yet. Add debts before Mia can prioritize payoff."
        },
        {
          item: "Runway transfer",
          amount: [ dollars(snapshot.fetch(:baseline_surplus_cents)), 0 ].max,
          recommendation: snapshot.fetch(:runway_months) < target_runway_months ? "Approve" : "Optional",
          reason: "Runway buys options and lowers panic."
        }
      ]
    end

    def targets
      [
        { label: "Emergency fund", current: dollars(account_by_type("emergency_fund")), target: dollars(snapshot.fetch(:total_outflow_cents) * target_runway_months) },
        { label: "Debt payoff", current: dollars(snapshot.fetch(:total_debt_cents)), target: 0 },
        { label: "Monthly business revenue", current: dollars(monthly_business_income_cents), target: dollars([ snapshot.fetch(:total_outflow_cents) - stable_income_cents, 0 ].max) }
      ]
    end

    def chat_messages
      return [] unless user

      session = household.chat_sessions.find_by(user: user)
      return [] unless session

      session.chat_messages.order(:created_at).last(24).map(&:as_api_json)
    end

    def income_by_type(source_type)
      household.income_sources.where(active: true, source_type: source_type).sum { |income| Money.monthly_cents(income.amount_cents, income.cadence) }
    end

    def expenses_by_stack(stack_key)
      household.expense_items.where(active: true, stack_key: stack_key).sum { |expense| Money.monthly_cents(expense.amount_cents, expense.cadence) }
    end

    def account_by_type(account_type)
      household.accounts.where(account_type: account_type).sum(&:balance_cents)
    end

    def non_emergency_assets_cents
      household.accounts.where.not(account_type: "emergency_fund").sum(&:balance_cents)
    end

    def debt_by_type(debt_type)
      household.debts.where(debt_type: debt_type).sum(&:balance_cents)
    end

    def debt_payments_by_type(debt_type)
      household.debts.where(debt_type: debt_type).sum(&:minimum_payment_cents)
    end

    def dollars(cents)
      Money.dollars(cents)
    end
  end
end
