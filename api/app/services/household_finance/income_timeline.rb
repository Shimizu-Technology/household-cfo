module HouseholdFinance
  class IncomeTimeline
    def self.recurring_monthly_cents(source, on: Date.current)
      recurring = source.income_schedule_entries
        .select { |entry| entry.entry_type == "recurring_change" && entry.effective_on <= on.to_date.end_of_month }
        .max_by(&:effective_on)
      recurring ? Money.monthly_cents(recurring.amount_cents, recurring.cadence) : Money.monthly_cents(source.amount_cents, source.cadence)
    end

    def self.period_cents(source, starts_on:, ends_on:)
      recurring_cents = recurring_monthly_cents(source, on: ends_on)
      one_time_cents = source.income_schedule_entries.sum do |entry|
        entry.entry_type == "one_time" && entry.effective_on.between?(starts_on, ends_on) ? entry.amount_cents : 0
      end

      recurring_cents + one_time_cents
    end
  end
end
