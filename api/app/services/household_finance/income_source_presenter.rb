module HouseholdFinance
  class IncomeSourcePresenter
    def self.collection(scope, reference_date: Date.current)
      sources = scope.includes(:income_schedule_entries).order(:source_type, :label, :starts_on, :id).to_a
      sources.map { |source| new(source, reference_date: reference_date).as_json }
    end

    def initialize(source, reference_date: Date.current)
      @source = source
      @reference_date = reference_date.to_date
    end

    def as_json
      {
        id: source.id,
        label: source.label,
        source_type: source.source_type,
        base_amount: Money.dollars(source.amount_cents),
        base_cadence: source.cadence,
        starts_on: source.starts_on&.iso8601,
        ends_on: source.ends_on&.iso8601,
        active: source.effective_on?(reference_date),
        timeline_status: source.timeline_status(on: reference_date),
        current_monthly_amount: Money.dollars(IncomeTimeline.recurring_monthly_cents(source, on: reference_date)),
        schedule_entries: source.income_schedule_entries.sort_by { |entry| [ entry.effective_on, entry.entry_type, entry.id ] }.map do |entry|
          {
            id: entry.id,
            entry_type: entry.entry_type,
            label: entry.label,
            amount: Money.dollars(entry.amount_cents),
            cadence: entry.cadence,
            effective_on: entry.effective_on.iso8601,
            retained_after_transition: entry.retained_after_transition?,
            active: source.schedule_entry_active?(entry)
          }
        end
      }
    end

    private

    attr_reader :source, :reference_date
  end
end
