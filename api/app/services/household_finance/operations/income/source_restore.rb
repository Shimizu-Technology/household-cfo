require_relative "source_update"

module HouseholdFinance
  module Operations
    module Income
      class SourceRestore < SourceUpdate
        KEY = "income.source.restore"

        private

        def normalize(input)
          { source_id: Integer(input.fetch(:source_id)), year: (input[:year].presence || Date.current.year).to_i }
        end

        def predicted_after(before, _input)
          changed = before.fetch("source").merge("active" => true, "ends_on" => nil)
          { source: changed, schedule_entries: before.fetch("schedule_entries"), conflicting_source_ids: before.fetch("conflicting_source_ids") }
        end

        def validate_execution!(subject, _input, prepared:, source:)
          if subject.ends_on && subject.ends_on < Date.current.beginning_of_month
            raise ArgumentError, "This income source ended in the past. Create a new source for resumed income so the archived gap stays accurate. Nothing changed."
          end
          if prepared.before_snapshot.fetch("conflicting_source_ids").any?
            raise ArgumentError, "An active income source already uses that name and type. Keep the archived source closed or rename the active source. Nothing changed."
          end
        end

        def mutate!(source, _input, prepared:)
          source.update!(active: true, ends_on: nil)
          source
        end
      end
    end
  end
end
