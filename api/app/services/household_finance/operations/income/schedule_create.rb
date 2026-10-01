require_relative "schedule_base"

module HouseholdFinance
  module Operations
    module Income
      class ScheduleCreate < ScheduleBase
        KEY = "income.schedule.create"
        VERSION = 1

        private

        def normalize(input)
          normalize_entry_values(input)
        end

        def subject_for(input, lock:)
          source_for_input(input, lock: lock)
        end

        def canonical_snapshot(source, input, lock:)
          source_snapshot(source, lock: lock)
        end

        def predicted_after(before, input)
          entry = {
            entry_type: input.fetch(:entry_type), label: input[:label], amount_cents: input.fetch(:amount_cents), cadence: input.fetch(:cadence),
            effective_on: input.fetch(:effective_on), retained_after_transition: input.fetch(:retained_after_transition)
          }
          {
            source: before.fetch("source"),
            schedule_entries: before.fetch("schedule_entries") + [ entry ],
            conflicting_source_ids: before.fetch("conflicting_source_ids")
          }
        end

        def validate_execution!(subject, input, prepared:, source:)
          validate_source_for_entry!(subject, input)
        end

        def mutate!(source, input, prepared:)
          source.income_schedule_entries.create!(entry_attributes_from_input(input))
        end
      end
    end
  end
end
