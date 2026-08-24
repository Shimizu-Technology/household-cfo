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

    def initialize(household, annual_budget_manager: nil, reference_date: Date.current)
      @household = household
      @reference_date = reference_date.to_date
      @annual_budget_manager = annual_budget_manager
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
        allocations = current_allocations.select { |allocation| allocation.budget_category.stack_key == stack_key }
        {
          label: STACK_LABELS.fetch(stack_key),
          color: STACK_COLORS.fetch(stack_key),
          amount: dollars(allocations.sum(&:planned_amount_cents)),
          description: STACK_DESCRIPTIONS.fetch(stack_key),
          examples: allocations.any? ? allocations.map { |allocation| allocation.budget_category.name }.first(4) : STACK_EXAMPLES.fetch(stack_key)
        }
      end
    end

    private

    attr_reader :household, :reference_date

    def annual_budget_manager
      @annual_budget_manager ||= AnnualBudgetManager.new(household, year: reference_date.year)
    end

    def current_period
      @current_period ||= annual_budget_manager.current_period_for(reference_date)
    end

    def current_allocations
      @current_allocations ||= BudgetAllocation
        .includes(:budget_category)
        .joins(:budget_category)
        .where(
          budget_period: current_period,
          budget_categories: { household_id: household.id, active: true }
        )
        .to_a
    end

    def active_income_sources
      @active_income_sources ||= begin
        sources = if association_loaded?(:income_sources)
          household.income_sources.select(&:active?)
        else
          household.income_sources.where(active: true).to_a
        end

        ActiveRecord::Associations::Preloader.new(
          records: sources,
          associations: :income_schedule_entries
        ).call
        sources
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
      @monthly_income_cents ||= active_income_sources.sum do |income|
        IncomeTimeline.recurring_monthly_cents(income, on: reference_date)
      end
    end

    def stack_totals_cents
      @stack_totals_cents ||= ExpenseItem::STACK_KEYS.index_with do |stack_key|
        current_allocations
          .select { |allocation| allocation.budget_category.stack_key == stack_key }
          .sum(&:planned_amount_cents)
      end
    end

    def total_expenses_cents
      @total_expenses_cents ||= stack_totals_cents.values.sum
    end

    def debt_payments_cents
      @debt_payments_cents ||= debts.sum(&:minimum_payment_cents)
    end

    def total_outflow_cents
      readiness_calculation.fetch(:total_outflow_cents)
    end

    def baseline_surplus_cents
      readiness_calculation.fetch(:baseline_surplus_cents)
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
      readiness_calculation.fetch(:runway_months)
    end

    def safe_to_spend_cents
      readiness_calculation.fetch(:safe_to_spend_cents)
    end

    def target_runway_months
      @target_runway_months ||= begin
        target_months = goals.find { |goal| goal.goal_type == "runway" }&.target_months
        parsed_months = target_months.to_f
        parsed_months.positive? ? parsed_months : DEFAULT_RUNWAY_TARGET_MONTHS
      end
    end

    def readiness_tone
      readiness_calculation.fetch(:readiness_tone)
    end

    def readiness_label
      readiness_calculation.fetch(:readiness_label)
    end

    def readiness_calculation
      @readiness_calculation ||= ReadinessCalculator.new(
        monthly_income_cents: monthly_income_cents,
        category_outflow_cents: total_expenses_cents,
        debt_minimums_cents: debt_payments_cents,
        protected_liquid_cents: liquid_assets_cents,
        target_runway_months: target_runway_months
      ).call
    end

    def profile_completeness
      @profile_completeness ||= ProfileCompletenessCalculator.new(
        household,
        income_sources: active_income_sources
      ).call
    end

    def dollars(cents)
      Money.dollars(cents)
    end
  end
end
