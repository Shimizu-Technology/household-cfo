module HouseholdFinance
  class IncomeTimeline
    def self.recurring_monthly_cents(source, on: Date.current)
      amount_cents, cadence = recurring_amount_and_cadence(source, on: on)
      Money.period_cents(amount_cents, cadence, month: on.to_date.month)
    end

    def self.period_cents(source, starts_on:, ends_on:)
      amount_cents, cadence = recurring_amount_and_cadence(source, on: ends_on)
      recurring_cents = Money.period_cents(amount_cents, cadence, month: starts_on.month)
      one_time_cents = source.income_schedule_entries.sum do |entry|
        entry.entry_type == "one_time" && entry.effective_on.between?(starts_on, ends_on) ? entry.amount_cents : 0
      end

      recurring_cents + one_time_cents
    end

    def self.recurring_amount_and_cadence(source, on:)
      recurring = source.income_schedule_entries
        .select { |entry| entry.entry_type == "recurring_change" && entry.effective_on <= on.to_date.end_of_month }
        .max_by(&:effective_on)
      recurring ? [ recurring.amount_cents, recurring.cadence ] : [ source.amount_cents, source.cadence ]
    end
    private_class_method :recurring_amount_and_cadence
  end
end
