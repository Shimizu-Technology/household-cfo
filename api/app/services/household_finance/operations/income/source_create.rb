require_relative "base"

module HouseholdFinance
  module Operations
    module Income
      class SourceCreate < Base
        KEY = "income.source.create"
        VERSION = 1

        private

        def normalize(input)
          starts_on = parse_month(input[:starts_on].presence || Date.current.iso8601, label: "Income start date")
          {
            label: normalized_label(input[:label]),
            source_type: normalized_type(input[:source_type].presence || "other"),
            amount_cents: normalized_amount(input),
            cadence: normalized_cadence(input[:cadence]),
            starts_on: starts_on.iso8601,
            year: (input[:year].presence || starts_on.year).to_i
          }
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          conflicts = household.income_sources.where(active: true, source_type: input.fetch(:source_type)).where("LOWER(label) = ?", input.fetch(:label).downcase)
          conflicts = conflicts.lock if lock
          { source: nil, schedule_entries: [], conflicting_source_ids: conflicts.order(:id).pluck(:id) }
        end

        def predicted_after(before, input)
          {
            source: {
              label: input.fetch(:label), source_type: input.fetch(:source_type), amount_cents: input.fetch(:amount_cents),
              cadence: input.fetch(:cadence), active: true, starts_on: input.fetch(:starts_on), ends_on: nil
            },
            schedule_entries: [], conflicting_source_ids: before.fetch("conflicting_source_ids")
          }
        end

        def mutate!(_household, input, prepared:)
          raise ActiveRecord::RecordInvalid.new(conflicting_record(input)) if prepared.before_snapshot.fetch("conflicting_source_ids").any?

          household.income_sources.create!(
            label: input.fetch(:label), source_type: input.fetch(:source_type), amount_cents: input.fetch(:amount_cents),
            cadence: input.fetch(:cadence), active: true, starts_on: Date.iso8601(input.fetch(:starts_on))
          )
        end

        def canonical_after_snapshot(source, _input, prepared:)
          source_snapshot(source.reload, lock: false)
        end

        def verify_after!(predicted, actual)
          verify_income_prediction!(predicted, actual)
        end

        def conflicting_record(input)
          household.income_sources.new(label: input.fetch(:label), source_type: input.fetch(:source_type)).tap(&:valid?)
        end

        def stale_message
          "An income source named #{stale_input&.fetch(:label, "that name")} already exists for that type. Nothing changed."
        end
      end
    end
  end
end
