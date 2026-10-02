module HouseholdFinance
  class WorkspaceSetupSaver
    Result = Struct.new(:replayed?, :operation_results, keyword_init: true)

    TEXT_FIELDS = %i[household_name primary_goal].freeze
    INCOME_FIELDS = { primary_income: [ "Primary income", "job" ], business_income: [ "Business income", "business" ] }.freeze
    BUDGET_FIELDS = {
      fixed_expenses: [ "Fixed essentials", "non_discretionary" ],
      flexible_spend: [ "Flexible spending", "discretionary" ],
      expected_sinking_fund: [ "Expected sinking fund", "sinking_expected" ],
      unexpected_sinking_fund: [ "Unexpected sinking fund", "sinking_unexpected" ]
    }.freeze
    ACCOUNT_FIELDS = { emergency_fund: [ "Emergency fund", "emergency_fund" ], other_assets: [ "Other assets", "other" ] }.freeze
    MONEY_FIELDS = (INCOME_FIELDS.keys + BUDGET_FIELDS.keys).freeze
    REQUIRED_MONEY_FIELDS = %i[primary_income fixed_expenses flexible_spend].freeze
    REQUIRED_LABELS = SetupUpdater::REQUIRED_LABELS.freeze

    def initialize(household, user:, attributes:, idempotency_key:, year: Date.current.year)
      @household = household
      @user = user
      @attributes = attributes.to_h.symbolize_keys.slice(*SetupUpdater::INPUT_KEYS)
      @idempotency_key = idempotency_key.to_s.strip
      @year = year.to_i
    end

    def call
      raise ArgumentError, "Idempotency-Key header is required" if idempotency_key.blank?
      raise ArgumentError, "Idempotency key is too long" if idempotency_key.length > 200
      return Result.new(replayed?: false, operation_results: []) if attributes.empty?

      normalized = normalize_attributes
      results = []
      household.transaction do
        household.lock!
        if household.household_operation_executions.exists?(idempotency_key: idempotency_key)
          results << run_confirmation(normalized)
        else
          manager.ensure_plan!
          operation_specs(normalized).each_with_index do |spec, index|
            results << runner.run(
              operation_key: spec.fetch(:operation_key),
              input: spec.fetch(:input),
              idempotency_key: step_key(index, spec.fetch(:operation_key))
            )
          end
          results << run_confirmation(normalized)
        end
      end

      Result.new(replayed?: results.all?(&:replayed?), operation_results: results)
    end

    private

    attr_reader :household, :user, :attributes, :idempotency_key, :year

    def normalize_attributes
      REQUIRED_MONEY_FIELDS.each do |field|
        next unless attributes.key?(field) && attributes.fetch(field).to_s.strip.blank?

        raise ArgumentError, "#{REQUIRED_LABELS.fetch(field)} is required; enter 0 when it does not apply"
      end

      attributes.each_with_object({}) do |(field, value), normalized|
        normalized[field] = if field == :household_name
          name = value.to_s.squish.truncate(120, omission: "…")
          raise ArgumentError, "Name can't be blank" if name.blank?
          name
        elsif field == :primary_goal
          value.to_s.squish.truncate(500, omission: "…").presence
        elsif MONEY_FIELDS.include?(field)
          Money.cents!(value, message: "#{setup_label(field)} must be a number with no more than two decimal places")
        elsif ACCOUNT_FIELDS.key?(field)
          value.to_s.strip.present? ? Money.cents!(value, message: "#{setup_label(field)} must be a number with no more than two decimal places") : nil
        elsif field == :target_runway_months
          normalize_runway(value)
        else
          value
        end
      end
    end

    def operation_specs(normalized)
      specs = []
      profile = profile_input(normalized)
      specs << { operation_key: "profile.household.update", input: profile } if profile.any?
      if normalized.key?(:primary_goal) && normalized[:primary_goal] != household.primary_goal
        specs << { operation_key: "goal.transition_policy.update", input: { label: normalized[:primary_goal] } }
      end
      INCOME_FIELDS.each { |field, (label, source_type)| add_income_spec(specs, normalized, field, label, source_type) }
      BUDGET_FIELDS.each { |field, (label, stack_key)| add_budget_spec(specs, normalized, field, label, stack_key) }
      ACCOUNT_FIELDS.each { |field, (label, account_type)| add_account_spec(specs, normalized, field, label, account_type) }
      add_runway_spec(specs, normalized)
      specs
    end

    def profile_input(normalized)
      input = {}
      input[:name] = normalized[:household_name] if normalized.key?(:household_name) && normalized[:household_name] != household.name
      input[:primary_goal] = normalized[:primary_goal] if normalized.key?(:primary_goal) && normalized[:primary_goal] != household.primary_goal
      input[:location] = "Guam" if household.location.blank?
      input[:stage] = "First cohort" if household.stage.blank?
      input
    end

    def add_income_spec(specs, normalized, field, label, source_type)
      return unless normalized.key?(field)

      cents = normalized.fetch(field)
      current = household.income_sources.where(source_type: source_type).to_a.select { |source| source.effective_on?(Date.current) }
      current_total = current.sum { |source| IncomeTimeline.recurring_monthly_cents(source, on: Date.current) }
      return if current_total == cents
      raise ArgumentError, "#{label} has multiple saved sources. Edit a specific income source so no detailed amount changes silently" if current.many?
      return if current.empty? && cents.zero?

      if current.empty?
        specs << {
          operation_key: "income.source.create",
          input: { label: label, source_type: source_type, amount_cents: cents, cadence: "monthly", historical_baseline: true, year: year }
        }
        return
      end

      source = current.first
      effective_on = Date.current.beginning_of_month
      entry = source.income_schedule_entries.find_by(entry_type: "recurring_change", effective_on: effective_on)
      input = {
        source_id: source.id, entry_type: "recurring_change", amount_cents: cents,
        cadence: "monthly", effective_on: effective_on.iso8601, year: year
      }
      if entry
        input[:entry_id] = entry.id
        specs << { operation_key: "income.schedule.update", input: input }
      else
        specs << { operation_key: "income.schedule.create", input: input }
      end
    end

    def add_budget_spec(specs, normalized, field, label, stack_key)
      return unless normalized.key?(field)

      cents = normalized.fetch(field)
      current_cents = household.expense_items.where(active: true, stack_key: stack_key).sum do |expense|
        Money.monthly_cents(expense.amount_cents, expense.cadence)
      end
      return if current_cents == cents

      categories = household.budget_categories.active.where(stack_key: stack_key).order(:id).to_a
      if categories.many?
        raise ArgumentError, "#{setup_label(field)} is tracked by multiple budget categories. Edit the specific categories so detailed planned dollars do not change silently"
      end
      if categories.empty?
        specs << {
          operation_key: "budget.category.create",
          input: { name: label, stack_key: stack_key, monthly_amount_cents: cents, month_numbers: (1..12).to_a, year: year }
        }
        return
      end

      category = categories.first
      allocations = category.budget_allocations.joins(budget_period: :budget_year)
        .where(budget_years: { household_id: household.id, year: year }).order("budget_periods.starts_on").to_a
      raise ArgumentError, "The annual budget is incomplete. Reload setup and try again." unless allocations.length == 12

      specs << {
        operation_key: "budget.allocation.set",
        input: {
          category_id: category.id, year: year,
          changes: allocations.map { |allocation| { allocation_id: allocation.id, after_cents: cents } }
        }
      }
    end

    def add_account_spec(specs, normalized, field, label, account_type)
      return unless normalized.key?(field)

      cents = normalized.fetch(field)
      accounts = household.accounts.active.where(account_type: account_type).order(:id).to_a
      current_known = accounts.any? && accounts.all?(&:balance_known?)
      current_cents = accounts.select(&:balance_known?).sum(&:balance_cents)
      return if cents.nil? ? !current_known : current_known && current_cents == cents
      if accounts.many?
        raise ArgumentError, "#{setup_label(field)} is tracked by multiple accounts. Edit a specific account so detailed balances do not change silently"
      end

      balance = cents.nil? ? { balance_state: "unknown" } : { balance_cents: cents, balance_as_of_on: Date.current.iso8601 }
      if accounts.one?
        specs << { operation_key: "account.record.update", input: { account_id: accounts.first.id }.merge(balance) }
      elsif cents.present?
        specs << {
          operation_key: "account.record.create",
          input: { label: label, account_type: account_type, source_type: "setup", source_metadata: { "setup_field" => field.to_s } }.merge(balance)
        }
      end
    end

    def add_runway_spec(specs, normalized)
      return unless normalized.key?(:target_runway_months)

      current = household.goals.policy.where(goal_type: "runway").order(:id).first&.target_months
      return if current && BigDecimal(current.to_s) == normalized.fetch(:target_runway_months)

      specs << { operation_key: "goal.runway_policy.update", input: { target_months: normalized.fetch(:target_runway_months).to_s("F") } }
    end

    def run_confirmation(normalized)
      unconfirmed = normalized.filter_map do |field, value|
        field.to_s if (field.in?(%i[emergency_fund other_assets]) && value.nil?) || (field == :primary_goal && value.blank?)
      end
      confirmed = normalized.keys.map(&:to_s) - unconfirmed
      expected = normalized.to_h do |field, value|
        display = if MONEY_FIELDS.include?(field) || ACCOUNT_FIELDS.key?(field)
          value.nil? ? nil : Money.dollars(value)
        elsif field == :target_runway_months
          value.to_s("F")
        else
          value
        end
        [ field.to_s, display ]
      end
      runner.run(
        operation_key: "profile.setup_confirmation.update",
        input: { confirmed_fields: confirmed, unconfirmed_fields: unconfirmed, expected_values: expected },
        idempotency_key: idempotency_key
      )
    end

    def manager
      @manager ||= AnnualBudgetManager.new(household, year: year)
    end

    def runner
      @runner ||= Operations::Runner.new(household, user: user)
    end

    def step_key(index, operation_key)
      digest = Digest::SHA256.hexdigest([ idempotency_key, index, operation_key ].join("\0"))[0, 32]
      "#{idempotency_key[0, 160]}:#{digest}"
    end

    def setup_label(field)
      return "Primary income" if field == :primary_income
      return "Business income" if field == :business_income

      MiaActionDraftHouseholdCommands::SETUP_LABELS.fetch(field)
    end

    def normalize_runway(value)
      months = BigDecimal(value.to_s.strip)
      raise ArgumentError unless months.finite? && months.positive? && months <= 120

      months
    rescue ArgumentError
      raise ArgumentError, "Target runway months must be a positive number"
    end
  end
end
