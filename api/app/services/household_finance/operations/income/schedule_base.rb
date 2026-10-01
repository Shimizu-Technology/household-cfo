require_relative "base"

module HouseholdFinance
  module Operations
    module Income
      class ScheduleBase < Base
        private

        def normalize_entry_values(input, require_id: false)
          type = input[:entry_type].presence || "recurring_change"
          raise ArgumentError, "Income schedule type is not supported" unless type.in?(IncomeScheduleEntry::ENTRY_TYPES)
          effective_on = parse_month(input.fetch(:effective_on), label: "Income schedule date")
          amount_cents = normalized_amount(input)
          raise ArgumentError, "One-time income must be greater than zero" if type == "one_time" && !amount_cents.positive?

          retained = if input.key?(:retained_after_transition)
            ActiveModel::Type::Boolean.new.cast(input[:retained_after_transition]) == true
          elsif require_id
            IncomeScheduleEntry.joins(:income_source)
              .where(income_sources: { household_id: household.id })
              .find_by(id: input[:entry_id])&.retained_after_transition? || false
          else
            false
          end
          values = {
            source_id: Integer(input.fetch(:source_id, input[:income_source_id])),
            entry_type: type,
            label: input[:label].to_s.squish.truncate(80, omission: "…").presence,
            amount_cents: amount_cents,
            cadence: normalized_cadence(input[:cadence], one_time: type == "one_time"),
            effective_on: effective_on.iso8601,
            retained_after_transition: retained,
            year: (input[:year].presence || effective_on.year).to_i
          }
          values[:entry_id] = Integer(input.fetch(:entry_id)) if require_id
          values
        end

        def source_for_input(input, lock:)
          scope = source_scope(lock: lock)
          scope.find(input.fetch(:source_id))
        end

        def validate_source_for_entry!(source, input)
          unless source.effective_on?(Date.iso8601(input.fetch(:effective_on)))
            raise ArgumentError, "Income source is not active for that month. Nothing changed."
          end
          if input.fetch(:retained_after_transition) && input.fetch(:source_id) && source.source_type != "job"
            raise ArgumentError, "Continuing transition income is available only for job income. Nothing changed."
          end
        end

        def entry_attributes_from_input(input)
          input.slice(:entry_type, :label, :amount_cents, :cadence, :retained_after_transition).merge(effective_on: Date.iso8601(input.fetch(:effective_on)))
        end

        def canonical_after_snapshot(subject, input, prepared:)
          source = subject.is_a?(IncomeSource) ? subject : subject.income_source
          source_snapshot(source.reload, lock: false)
        end

        def verify_after!(predicted, actual)
          verify_income_prediction!(predicted, actual)
        end
      end
    end
  end
end
