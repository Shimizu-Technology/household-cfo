# frozen_string_literal: true

module HouseholdFinance
  # Saved income is a timeline, not a collection of interchangeable monthly
  # amounts. This reader uses the same period calculation as the annual budget.
  class SavedIncomeInventory
    MAX_RECORDS = 50
    MAX_SCHEDULE_ENTRIES = 12

    def initialize(household, on:, record_limit: MAX_RECORDS, schedule_limit: MAX_SCHEDULE_ENTRIES)
      @household, @on = household, on.to_date.beginning_of_month
      @record_limit, @schedule_limit = record_limit, schedule_limit
    end

    def call
      sources = @household.income_sources.includes(:income_schedule_entries).order(:source_type, :label, :starts_on, :id).to_a
      recurring = sources.sum { |source| IncomeTimeline.recurring_monthly_cents(source, on: @on) }
      period = sources.sum { |source| IncomeTimeline.period_cents(source, starts_on: @on, ends_on: @on.end_of_month) }
      {
        scope: "saved_household_income",
        starts_on: @on.iso8601,
        ends_on: @on.end_of_month.iso8601,
        total_count: sources.length,
        shown_count: [ sources.length, @record_limit ].min,
        coverage: sources.length > @record_limit ? "bounded_saved_records" : "all_saved_records",
        completeness_note: "Saved sources may not cover all household income. No recorded sources does not establish zero income. Monthly equivalents are planning amounts, not verified deposits or pay dates.",
        recurring_monthly_amount: sources.any? ? Money.dollars(recurring) : nil,
        selected_month_amount: sources.any? ? Money.dollars(period) : nil,
        records: sources.first(@record_limit).map { |source| serialize_source(source) }
      }
    end

    private

    def serialize_source(source)
      entries = source.income_schedule_entries.sort_by { |entry| [ entry.effective_on, entry.entry_type, entry.id ] }
      effective = entries.select { |entry| entry.entry_type == "recurring_change" && entry.effective_on <= @on.end_of_month }.max_by(&:effective_on)
      eligible = source.effective_on?(@on)
      upcoming = entries.select { |entry| entry.effective_on >= @on }
      {
        id: source.id,
        label: source.label,
        source_type: source.source_type,
        base_amount: Money.dollars(source.amount_cents),
        base_cadence: source.cadence,
        starts_on: source.starts_on&.iso8601,
        ends_on: source.ends_on&.iso8601,
        timeline_status: source.timeline_status(on: @on),
        effective_amount: eligible ? Money.dollars(effective ? effective.amount_cents : source.amount_cents) : nil,
        effective_cadence: eligible ? (effective ? effective.cadence : source.cadence) : nil,
        recurring_monthly_amount: Money.dollars(IncomeTimeline.recurring_monthly_cents(source, on: @on)),
        selected_month_amount: Money.dollars(IncomeTimeline.period_cents(source, starts_on: @on, ends_on: @on.end_of_month)),
        schedule_total_count: entries.length,
        upcoming_schedule_count: upcoming.length,
        schedule_coverage: upcoming.length > @schedule_limit ? "bounded_current_and_future_entries" : "all_current_and_future_entries",
        schedule_entries: upcoming.first(@schedule_limit).map do |entry|
          {
            id: entry.id, entry_type: entry.entry_type, label: entry.label,
            amount: Money.dollars(entry.amount_cents), cadence: entry.cadence,
            effective_on: entry.effective_on.iso8601,
            active: source.schedule_entry_active?(entry),
            retained_after_transition: entry.retained_after_transition?
          }
        end
      }
    end
  end
end
