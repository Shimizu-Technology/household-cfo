require_relative "source_update"

module HouseholdFinance
  module Operations
    module Income
      class SourceArchive < SourceUpdate
        KEY = "income.source.archive"

        private

        def normalize(input)
          ends_on = parse_month(input[:ends_on].presence || Date.current.iso8601, label: "Income end date")
          { source_id: Integer(input.fetch(:source_id)), ends_on: ends_on.iso8601, year: (input[:year].presence || ends_on.year).to_i }
        end

        def predicted_after(before, input)
          changed = before.fetch("source").merge("active" => false, "ends_on" => input.fetch(:ends_on))
          { source: changed, schedule_entries: before.fetch("schedule_entries"), conflicting_source_ids: before.fetch("conflicting_source_ids") }
        end

        def validate_execution!(subject, input, prepared:, source:)
          ending = Date.iso8601(input.fetch(:ends_on))
          if subject.starts_on && ending <= subject.starts_on
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
