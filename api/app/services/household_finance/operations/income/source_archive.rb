require_relative "source_update"

module HouseholdFinance
  module Operations
    module Income
      class SourceArchive < SourceUpdate
        KEY = "income.source.archive"

        private

        def normalize(input)
          ends_on = parse_month(input[:ends_on].presence || Date.current.iso8601, label: "Income end date")
          source_id = Integer(input.fetch(:source_id))
          source = household.income_sources.find_by(id: source_id)
          if source&.starts_on&.future? && ends_on <= source.starts_on
            ends_on = source.starts_on
          end
          { source_id: source_id, ends_on: ends_on.iso8601, year: (input[:year].presence || ends_on.year).to_i }
        end

        def predicted_after(before, input)
          changed = before.fetch("source").merge("active" => false, "ends_on" => input.fetch(:ends_on))
          { source: changed, schedule_entries: schedule_entries_with_activity(before.fetch("schedule_entries"), changed), conflicting_source_ids: before.fetch("conflicting_source_ids") }
        end

        def canonical_snapshot(source, input, lock:)
          source_snapshot(
            source,
            lock: lock,
            candidate_ends_on: input.fetch(:ends_on),
            candidate_active: false
          )
        end

        def validate_execution!(subject, input, prepared:, source:)
          ending = Date.iso8601(input.fetch(:ends_on))
          if subject.starts_on && ending < subject.starts_on
            raise ArgumentError, "Income end date must be after its starting month. Nothing changed."
          end
          if subject.starts_on && ending == subject.starts_on && subject.starts_on <= Date.current.beginning_of_month
            raise ArgumentError, "Income end date must be after its starting month. Nothing changed."
          end
        end

        def mutate!(source, input, prepared:)
          source.update!(active: false, ends_on: Date.iso8601(input.fetch(:ends_on)))
          source
        end
      end
    end
  end
end
