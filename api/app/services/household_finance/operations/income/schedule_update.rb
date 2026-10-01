require_relative "schedule_base"

module HouseholdFinance
  module Operations
    module Income
      class ScheduleUpdate < ScheduleBase
        KEY = "income.schedule.update"
        VERSION = 1

        private

        def normalize(input)
          normalize_entry_values(input, require_id: true)
        end

        def subject_for(input, lock:)
          entry_scope = IncomeScheduleEntry.joins(:income_source).where(income_sources: { household_id: household.id })
          entry_scope = entry_scope.lock if lock
          entry = entry_scope.find(input.fetch(:entry_id))
          raise ActiveRecord::RecordNotFound, "Income schedule entry not found" unless entry.income_source_id == input.fetch(:source_id)
          entry.income_source.lock! if lock
          entry.income_source
        end

        def canonical_snapshot(source, input, lock:)
          snapshot = source_snapshot(source, lock: lock)
          unless snapshot.fetch(:schedule_entries).any? { |entry| entry.fetch(:id) == input.fetch(:entry_id) }
            raise ActiveRecord::RecordNotFound, "Income schedule entry not found"
          end
          snapshot
        end

        def predicted_after(before, input)
          entries = before.fetch("schedule_entries").map do |entry|
            next entry unless entry.fetch("id") == input.fetch(:entry_id)
            entry.merge(
              "entry_type" => input.fetch(:entry_type), "label" => input[:label], "amount_cents" => input.fetch(:amount_cents),
              "cadence" => input.fetch(:cadence), "effective_on" => input.fetch(:effective_on),
              "retained_after_transition" => input.fetch(:retained_after_transition), "active" => true
            )
          end
          { source: before.fetch("source"), schedule_entries: entries, conflicting_source_ids: before.fetch("conflicting_source_ids") }
        end

        def validate_execution!(subject, input, prepared:, source:)
          validate_source_for_entry!(subject, input)
        end

        def mutate!(source, input, prepared:)
          entry = source.income_schedule_entries.lock.find(input.fetch(:entry_id))
          entry.update!(entry_attributes_from_input(input))
          source
        end
      end
    end
  end
end
