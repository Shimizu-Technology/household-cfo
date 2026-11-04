module HouseholdFinance
  # A new plan starts when the household joins. Income knowledge is separate
  # from schedule arithmetic: a subtotal never establishes the missing salary.
  class PlanCoverage
    def initialize(household)
      @household = household
    end

    def starts_on
      household.created_at.in_time_zone.to_date.beginning_of_month
    end

    def month_numbers(year)
      (1..12).select { |month| Date.new(year, month, 1) >= starts_on }
    end

    def income_known?(date)
      return false if date.end_of_month < starts_on

      sources = @sources ||= household.income_sources.to_a
      current = sources.select { |source| source.effective_on?(date.end_of_month) }
      primary_confirmed = @confirmed_fields ||= SetupStatus.new(household).confirmed_field_keys
      primary_confirmed = primary_confirmed.include?("primary_income")
      return false unless primary_confirmed || current.any? { |source| source.source_type == "job" }

      current.any? || (primary_confirmed && sources.all? { |source| source.source_type != "job" && source.starts_on && source.starts_on > date.end_of_month })
    end

    private

    attr_reader :household
  end
end
