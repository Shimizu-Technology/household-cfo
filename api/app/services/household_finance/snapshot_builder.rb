module HouseholdFinance
  class SnapshotBuilder
    STACK_LABELS = {
      "non_discretionary" => "Non-discretionary",
      "discretionary" => "Discretionary",
      "sinking_expected" => "Sinking Fund — Expected",
      "sinking_unexpected" => "Sinking Fund — Unexpected"
    }.freeze

    STACK_COLORS = {
      "non_discretionary" => "green",
      "discretionary" => "yellow",
      "sinking_expected" => "gold",
      "sinking_unexpected" => "red"
    }.freeze

    STACK_DESCRIPTIONS = {
      "non_discretionary" => "Fixed, non-negotiable monthly obligations.",
      "discretionary" => "Choices that still matter, but can be shaped.",
      "sinking_expected" => "Known irregular expenses that should stop feeling like surprises.",
      "sinking_unexpected" => "Life-happens money for repairs, medical, and family support."
    }.freeze

    STACK_EXAMPLES = {
      "non_discretionary" => [ "Mortgage/rent", "utilities", "insurance", "minimum debt payments" ],
      "discretionary" => [ "groceries", "coffee", "eating out", "subscriptions" ],
      "sinking_expected" => [ "car registration", "back to school", "holidays" ],
      "sinking_unexpected" => [ "car repair", "clinic visit", "appliance replacement" ]
    }.freeze

    DEFAULT_RUNWAY_TARGET_MONTHS = 6.0

    def initialize(household)
      @household = household
    end

    def call
      {
        monthly_income_cents: monthly_income_cents,
        stack_totals_cents: stack_totals_cents,
        total_expenses_cents: total_expenses_cents,
        debt_payments_cents: debt_payments_cents,
        total_outflow_cents: total_outflow_cents,
        baseline_surplus_cents: baseline_surplus_cents,
        liquid_assets_cents: liquid_assets_cents,
        total_assets_cents: total_assets_cents,
        total_debt_cents: total_debt_cents,
        net_worth_cents: net_worth_cents,
        runway_months: runway_months,
        target_runway_months: target_runway_months,
        safe_to_spend_cents: safe_to_spend_cents,
        readiness_label: readiness_label,
        readiness_tone: readiness_tone,
        profile_completeness: profile_completeness
      }
    end

    def budget_stacks
      ExpenseItem::STACK_KEYS.map do |stack_key|
        items = active_expenses.select { |expense| expense.stack_key == stack_key }
        {
          label: STACK_LABELS.fetch(stack_key),
          color: STACK_COLORS.fetch(stack_key),
          amount: dollars(items.sum { |expense| monthly_cents(expense.amount_cents, expense.cadence) }),
          description: STACK_DESCRIPTIONS.fetch(stack_key),
          examples: items.any? ? items.map(&:label).first(4) : STACK_EXAMPLES.fetch(stack_key)
        }
      end
    end

    private

    attr_reader :household

    def active_income_sources
      @active_income_sources ||= if association_loaded?(:income_sources)
        household.income_sources.select(&:active?)
      else
        household.income_sources.where(active: true).to_a
      end
    end

    def active_expenses
      @active_expenses ||= if association_loaded?(:expense_items)
        household.expense_items.select(&:active?)
      else
        household.expense_items.where(active: true).to_a
      end
    end

    def debts
      @debts ||= association_records(:debts)
    end

    def accounts
      @accounts ||= association_records(:accounts)
    end

    def goals
      @goals ||= if association_loaded?(:goals)
        household.goals.sort_by { |goal| [ goal_priority_sort_value(goal), goal.created_at || null_sort_time ] }
      else
        household.goals.order(:priority, :created_at).to_a
      end
    end

    def goal_priority_sort_value(goal)
      goal.priority.nil? ? Float::INFINITY : goal.priority
    end

    def null_sort_time
      @null_sort_time ||= Time.zone.local(9999, 12, 31)
    end

    def association_records(name)
      household.public_send(name).to_a
    end

    def association_loaded?(name)
      household.association(name).loaded?
    end

    def monthly_income_cents
      @monthly_income_cents ||= active_income_sources.sum { |income| monthly_cents(income.amount_cents, income.cadence) }
    end

    def stack_totals_cents
      @stack_totals_cents ||= ExpenseItem::STACK_KEYS.index_with do |stack_key|
        active_expenses.select { |expense| expense.stack_key == stack_key }.sum { |expense| monthly_cents(expense.amount_cents, expense.cadence) }
      end
    end

    def total_expenses_cents
      @total_expenses_cents ||= stack_totals_cents.values.sum
    end

    def debt_payments_cents
      @debt_payments_cents ||= debts.sum(&:minimum_payment_cents)
    end

    def total_outflow_cents
      total_expenses_cents + debt_payments_cents
    end

    def baseline_surplus_cents
      monthly_income_cents - total_outflow_cents
    end

    def liquid_assets_cents
      @liquid_assets_cents ||= accounts.select(&:liquid?).sum(&:balance_cents)
    end

    def total_assets_cents
      @total_assets_cents ||= accounts.sum(&:balance_cents)
    end

    def total_debt_cents
      @total_debt_cents ||= debts.sum(&:balance_cents)
    end

    def net_worth_cents
      total_assets_cents - total_debt_cents
    end

    def runway_months
      need = total_outflow_cents
      return 0.0 if need <= 0

      (liquid_assets_cents / need.to_f).round(1)
    end

    def safe_to_spend_cents
      return 0 if baseline_surplus_cents <= 0

      (baseline_surplus_cents * 0.4).round
    end

    def target_runway_months
      @target_runway_months ||= begin
        target_months = goals.find { |goal| goal.goal_type == "runway" }&.target_months
        parsed_months = target_months.to_f
        parsed_months.positive? ? parsed_months : DEFAULT_RUNWAY_TARGET_MONTHS
      end
    end

    def readiness_tone
      return "green" if runway_months >= target_runway_months && baseline_surplus_cents.positive?
      return "yellow" if runway_months >= (target_runway_months / 2.0) && baseline_surplus_cents >= 0

      "red"
    end

    def readiness_label
      case readiness_tone
      when "green"
        "Green — steady, keep building"
      when "yellow"
        "Yellow — close, but protect runway"
      else
        "Red — pause and stabilize basics"
      end
    end

    def profile_completeness
      checks = [
        household.name.present?,
        household.primary_goal.present?,
        active_income_sources.any? { |income| income.amount_cents.positive? },
        active_expenses.any? { |expense| expense.amount_cents.positive? },
        accounts.any? { |account| account.balance_cents.positive? },
        debts.any? || accounts.any?,
        goals.any?
      ]

      ((checks.count(true) / checks.length.to_f) * 100).round
    end

    def monthly_cents(amount_cents, cadence)
      Money.monthly_cents(amount_cents, cadence)
    end

    def dollars(cents)
      Money.dollars(cents)
    end
  end
end
