require_relative "schedule_base"

module HouseholdFinance
  module Operations
    module Income
      class ScheduleDelete < ScheduleBase
        KEY = "income.schedule.delete"
        VERSION = 1

        private

        def normalize(input)
          { entry_id: Integer(input.fetch(:entry_id)), source_id: Integer(input.fetch(:source_id, input[:income_source_id])), year: (input[:year].presence || Date.current.year).to_i }
        end

        def subject_for(input, lock:)
          scope = IncomeScheduleEntry.joins(:income_source).where(income_sources: { household_id: household.id })
          scope = scope.lock if lock
          entry = scope.find(input.fetch(:entry_id))
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
          {
            source: before.fetch("source"),
            schedule_entries: before.fetch("schedule_entries").reject { |entry| entry.fetch("id") == input.fetch(:entry_id) },
            conflicting_source_ids: before.fetch("conflicting_source_ids")
          }
        end

        def mutate!(source, input, prepared:)
          source.income_schedule_entries.lock.find(input.fetch(:entry_id)).destroy!
          source
        end
      end
    end
  end
end
