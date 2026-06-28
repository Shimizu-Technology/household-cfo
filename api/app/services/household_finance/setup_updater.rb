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
    MISSING_VALUE = Object.new.freeze

    def initialize(household, attributes)
      @household = household
      @attributes = attributes.to_h.symbolize_keys.slice(*INPUT_KEYS)
    end

    def call
      household.with_lock do
        update_household
        upsert_income("Primary income", "job", attributes[:primary_income]) if attributes.key?(:primary_income)
        upsert_income("Business income", "business", attributes[:business_income]) if attributes.key?(:business_income)
        upsert_expense("Fixed essentials", "non_discretionary", attributes[:fixed_expenses]) if attributes.key?(:fixed_expenses)
        upsert_expense("Flexible spending", "discretionary", attributes[:flexible_spend]) if attributes.key?(:flexible_spend)
        upsert_expense("Expected sinking fund", "sinking_expected", attributes[:expected_sinking_fund]) if attributes.key?(:expected_sinking_fund)
        upsert_expense("Unexpected sinking fund", "sinking_unexpected", attributes[:unexpected_sinking_fund]) if attributes.key?(:unexpected_sinking_fund)
        upsert_account("Emergency fund", "emergency_fund", attributes[:emergency_fund]) if attributes.key?(:emergency_fund)
        upsert_account("Other assets", "other", attributes[:other_assets]) if attributes.key?(:other_assets)
        upsert_credit_card_debt if attributes.key?(:credit_card_debt) || attributes.key?(:debt_payment)
        upsert_runway_goal if attributes.key?(:target_runway_months)
        upsert_transition_goal
      end

      household.reload
    end

    private

    attr_reader :household, :attributes

    def update_household
      household.assign_attributes(
        location: household.location.presence || "Guam",
        stage: household.stage.presence || "First cohort"
      )
      household.name = bounded_text(attributes[:household_name], max_length: 120, allow_blank: false) if attributes.key?(:household_name)
      household.primary_goal = bounded_text(attributes[:primary_goal], max_length: 500, allow_blank: true) if attributes.key?(:primary_goal)
      household.save!
    end

    def upsert_income(label, source_type, value)
      cents = Money.cents(value)
      scope = household.income_sources.where(source_type: source_type)
      aggregate = scope.find_by(label: label)
      return if aggregate.blank? && active_monthly_total(scope) == cents

      record = aggregate || scope.order(:id).first || household.income_sources.new(source_type: source_type)
      deactivate_other_records(scope, record)
      record.update!(label: label, amount_cents: cents, cadence: "monthly", active: cents.positive?)
    end

    def upsert_expense(label, stack_key, value)
      cents = Money.cents(value)
      scope = household.expense_items.where(stack_key: stack_key)
      aggregate = scope.find_by(label: label)
      return if aggregate.blank? && active_monthly_total(scope) == cents

      record = aggregate || scope.order(:id).first || household.expense_items.new(stack_key: stack_key)
      deactivate_other_records(scope, record)
      record.update!(label: label, amount_cents: cents, cadence: "monthly", active: cents.positive?)
    end

    def upsert_account(label, account_type, value)
      cents = Money.cents(value)
      record = household.accounts.find_or_initialize_by(label: label, account_type: account_type)
      record.update!(balance_cents: cents)
    end

    def upsert_credit_card_debt
      upsert_debt(
        "Credit card debt",
        "credit_card",
        attributes.fetch(:credit_card_debt, MISSING_VALUE),
        attributes.fetch(:debt_payment, MISSING_VALUE)
      )
    end

    def upsert_debt(label, debt_type, balance, payment)
      scope = household.debts.where(debt_type: debt_type)
      aggregate = scope.find_by(label: label)
      current_balance_cents = scope.sum(:balance_cents)
      current_payment_cents = scope.sum(:minimum_payment_cents)
      balance_cents = missing_value?(balance) ? (aggregate ? existing_cents(aggregate, :balance_cents) : current_balance_cents) : Money.cents(balance)
      payment_cents = missing_value?(payment) ? (aggregate ? existing_cents(aggregate, :minimum_payment_cents) : current_payment_cents) : Money.cents(payment)
      return if aggregate.blank? && current_balance_cents == balance_cents && current_payment_cents == payment_cents
      return if aggregate.blank? && scope.many?

      record = aggregate || scope.order(:id).first || household.debts.new(debt_type: debt_type)
      return record.destroy! if record.persisted? && balance_cents.zero?
      return if balance_cents.zero?

      record.update!(label: label, debt_type: debt_type, balance_cents: balance_cents, minimum_payment_cents: payment_cents)
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
      return unless attributes.key?(:primary_goal)

      if attributes[:primary_goal].blank?
        household.goals.where(goal_type: "transition").destroy_all
        return
      end

      goal = household.goals.where(goal_type: "transition").order(:priority, :created_at).first_or_initialize
      goal.update!(label: bounded_text(attributes[:primary_goal], max_length: 80, allow_blank: false), priority: 2)
    end

    def bounded_text(value, max_length:, allow_blank:)
      text = value.to_s.squish.truncate(max_length, omission: "…")
      return nil if allow_blank && text.blank?

      text
    end

    def active_monthly_total(scope)
      scope.where(active: true).sum { |record| Money.monthly_cents(record.amount_cents, record.cadence) }
    end

    def deactivate_other_records(scope, record)
      return unless record.persisted?

      scope.where.not(id: record.id).update_all(active: false, updated_at: Time.current)
    end

    def existing_cents(record, attribute)
      record.persisted? ? record.public_send(attribute) : 0
    end

    def missing_value?(value)
      value.equal?(MISSING_VALUE)
    end
  end
end
