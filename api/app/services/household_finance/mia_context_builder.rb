module HouseholdFinance
  class MiaContextBuilder
    def initialize(household)
      @household = household
      @presenter = DataPresenter.new(household)
      @snapshot = SnapshotBuilder.new(household).call
    end

    def call
      <<~CONTEXT.squish
        Current household context: household name is #{household.name}; primary goal is #{household.primary_goal.presence || "not set yet"};
        monthly income is #{money(snapshot.fetch(:monthly_income_cents))}; planned monthly outflow is #{money(snapshot.fetch(:total_outflow_cents))};
        baseline surplus is #{money(snapshot.fetch(:baseline_surplus_cents))}; safe-to-spend is #{money(snapshot.fetch(:safe_to_spend_cents))};
        runway is #{snapshot.fetch(:runway_months)} months; readiness is #{snapshot.fetch(:readiness_label)};
        total debt entered is #{money(snapshot.fetch(:total_debt_cents))}; liquid assets are #{money(snapshot.fetch(:liquid_assets_cents))}.
        Expense Stack totals: #{expense_stack_summary}.
        Use these numbers as context for coaching. If data is missing or zero, ask the user to add the missing number instead of pretending it is known.
      CONTEXT
    end

    private

    attr_reader :household, :presenter, :snapshot

    def expense_stack_summary
      presenter.budget.fetch(:stacks).map { |stack| "#{stack.fetch(:label)} #{money_dollars(stack.fetch(:amount))}" }.join("; ")
    end

    def money(cents)
      money_dollars(HouseholdFinance::Money.dollars(cents))
    end

    def money_dollars(amount)
      ActiveSupport::NumberHelper.number_to_currency(amount, precision: 0)
    end
  end
end
