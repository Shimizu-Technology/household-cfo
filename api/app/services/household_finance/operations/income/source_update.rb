require_relative "base"

module HouseholdFinance
  module Operations
    module Income
      class SourceUpdate < Base
        KEY = "income.source.update"
        VERSION = 1

        private

        def normalize(input)
          values = { source_id: Integer(input.fetch(:source_id)), year: (input[:year].presence || Date.current.year).to_i }
          values[:label] = normalized_label(input[:label]) if input.key?(:label)
          values[:source_type] = normalized_type(input[:source_type]) if input.key?(:source_type)
          values[:amount_cents] = normalized_amount(input) if input.key?(:amount_cents) || input.key?(:amount)
          values[:cadence] = normalized_cadence(input[:cadence]) if input.key?(:cadence)
          values[:starts_on] = parse_month(input[:starts_on], label: "Income start date").iso8601 if input.key?(:starts_on)
          raise ArgumentError, "Choose at least one income source field to update" if values.keys == %i[source_id year]
          values
        end

        def subject_for(input, lock:)
          scope = source_scope(lock: lock)
          scope.find(input.fetch(:source_id))
        end

        def canonical_snapshot(source, input, lock:)
          source_snapshot(
            source,
            lock: lock,
            candidate_label: input[:label].presence || source.label,
            candidate_type: input[:source_type].presence || source.source_type,
            candidate_starts_on: input.key?(:starts_on) ? input.fetch(:starts_on) : source.starts_on,
            candidate_ends_on: source.ends_on,
            candidate_active: source.active?
          )
        end

        def predicted_after(before, input)
          changed = before.fetch("source").merge(input.slice(:label, :source_type, :amount_cents, :cadence, :starts_on).stringify_keys)
          { source: changed, schedule_entries: schedule_entries_with_activity(before.fetch("schedule_entries"), changed), conflicting_source_ids: before.fetch("conflicting_source_ids") }
        end

        def validate_execution!(subject, input, prepared:, source:)
          target_type = input[:source_type].presence || subject.source_type
          if target_type != "job" && subject.income_schedule_entries.any?(&:retained_after_transition?)
            raise ArgumentError, "Clear continuing transition income before changing this source from job income. Nothing changed."
          end
          if input.key?(:starts_on)
            start_date = Date.iso8601(input.fetch(:starts_on))
            if subject.income_schedule_entries.where("effective_on < ?", start_date).exists?
              raise ArgumentError, "Income cannot start after one of its saved timeline changes. Move or remove that change first. Nothing changed."
            end
          end
        end

        def mutate!(source, input, prepared:)
          if prepared.before_snapshot.fetch("conflicting_source_ids").any?
            source.errors.add(:starts_on, "overlaps another income source with this name and type")
            raise ActiveRecord::RecordInvalid, source
          end
          attributes = input.slice(:label, :source_type, :amount_cents, :cadence)
          attributes[:starts_on] = Date.iso8601(input.fetch(:starts_on)) if input.key?(:starts_on)
          source.update!(attributes)
          source
        end

        def canonical_after_snapshot(source, input, prepared:)
          source_snapshot(source.reload, lock: false)
        end

        def verify_after!(predicted, actual)
          verify_income_prediction!(predicted, actual)
        end
      end
    end
  end
end
