module HouseholdFinance
  class SetupUpdater
    INPUT_KEYS = %i[
      household_name
      primary_goal
      primary_income
      business_income
      fixed_expenses
      flexible_spend
      expected_sinking_fund
      unexpected_sinking_fund
      emergency_fund
      other_assets
      credit_card_debt
      debt_payment
      target_runway_months
    ].freeze

    def initialize(household, attributes)
      @household = household
      @attributes = attributes.to_h.symbolize_keys.slice(*INPUT_KEYS)
    end

    def call
      Household.transaction do
        update_household
        upsert_income("Primary income", "job", attributes[:primary_income])
        upsert_income("Business income", "business", attributes[:business_income])
        upsert_expense("Fixed essentials", "non_discretionary", attributes[:fixed_expenses])
        upsert_expense("Flexible spending", "discretionary", attributes[:flexible_spend])
        upsert_expense("Expected sinking fund", "sinking_expected", attributes[:expected_sinking_fund])
        upsert_expense("Unexpected sinking fund", "sinking_unexpected", attributes[:unexpected_sinking_fund])
        upsert_account("Emergency fund", "emergency_fund", attributes[:emergency_fund])
        upsert_account("Other assets", "other", attributes[:other_assets])
        upsert_debt("Credit card debt", "credit_card", attributes[:credit_card_debt], attributes[:debt_payment])
        upsert_runway_goal
        upsert_transition_goal
      end

      household.reload
    end

    private

    attr_reader :household, :attributes

    def update_household
      household.update!(
        name: bounded_text(attributes[:household_name], fallback: household.name, max_length: 120),
        primary_goal: bounded_text(attributes[:primary_goal], fallback: household.primary_goal, max_length: 500),
        location: household.location.presence || "Guam",
        stage: household.stage.presence || "First cohort"
      )
    end

    def upsert_income(label, source_type, value)
      cents = Money.cents(value)
      record = household.income_sources.find_or_initialize_by(label: label, source_type: source_type)
      record.update!(amount_cents: cents, cadence: "monthly", active: cents.positive?)
    end

    def upsert_expense(label, stack_key, value)
      cents = Money.cents(value)
      record = household.expense_items.find_or_initialize_by(label: label, stack_key: stack_key)
      record.update!(amount_cents: cents, cadence: "monthly", active: cents.positive?)
    end

    def upsert_account(label, account_type, value)
      cents = Money.cents(value)
      record = household.accounts.find_or_initialize_by(label: label, account_type: account_type)
      record.update!(balance_cents: cents)
    end

    def upsert_debt(label, debt_type, balance, payment)
      balance_cents = Money.cents(balance)
      payment_cents = Money.cents(payment)
      record = household.debts.find_or_initialize_by(label: label, debt_type: debt_type)
      record.update!(balance_cents: balance_cents, minimum_payment_cents: payment_cents)
    end

    def upsert_runway_goal
      target_months = BigDecimal(attributes[:target_runway_months].to_s.presence || "6")
      target_months = 6 if target_months <= 0
      goal = household.goals.find_or_initialize_by(goal_type: "runway", label: "Runway target")
      goal.update!(target_months: target_months, priority: 1)
    rescue ArgumentError
      goal = household.goals.find_or_initialize_by(goal_type: "runway", label: "Runway target")
      goal.update!(target_months: 6, priority: 1)
    end

    def upsert_transition_goal
      return if attributes[:primary_goal].blank?

      goal = household.goals.where(goal_type: "transition").order(:priority, :created_at).first_or_initialize
      goal.update!(label: bounded_text(attributes[:primary_goal], fallback: "Transition goal", max_length: 80), priority: 2)
    end

    def bounded_text(value, fallback:, max_length:)
      value.to_s.presence&.squish&.truncate(max_length, omission: "…") || fallback
    end
  end
end
