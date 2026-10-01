module HouseholdFinance
  module Operations
    module Income
      class Base < Operations::Base
        INCOME_STALE_MESSAGE = "The income timeline changed since Mia prepared this review. Ask Mia to draft a fresh update. Nothing changed."

        private

        def ensure_plan!(_input)
          true
        end

        def parse_month(value, label: "Income date")
          date = Date.iso8601(value.to_s).beginning_of_month
          unless AnnualBudgetManager.supported_year?(date.year)
            raise ArgumentError, "#{label} is outside the supported range"
          end
          date
        rescue Date::Error
          raise ArgumentError, "#{label} must be a valid date"
        end

        def normalized_label(value)
          label = value.to_s.squish.truncate(120, omission: "…")
          raise ArgumentError, "Income source name is required" if label.blank?
          label
        end

        def normalized_type(value)
          type = value.to_s
          raise ArgumentError, "Income source type is not supported" unless type.in?(IncomeSource::SOURCE_TYPES)
          type
        end

        def normalized_cadence(value, one_time: false)
          cadence = one_time ? "one_time" : value.to_s.presence || "monthly"
          raise ArgumentError, "Income cadence is not supported" unless cadence.in?(IncomeSource::CADENCES)
          raise ArgumentError, "Recurring income cadence cannot be one_time" if !one_time && cadence == "one_time"
          cadence
        end

        def normalized_amount(input, cents_key: :amount_cents, amount_key: :amount, message: "Income amount must be a number")
          cents = if input.key?(cents_key)
            Integer(input.fetch(cents_key))
          else
            Money.cents!(input.fetch(amount_key), message: message)
          end
          raise ArgumentError, "Income amount must be zero or more" if cents.negative?
          cents
        rescue TypeError
          raise ArgumentError, message
        end

        def source_scope(lock: false)
          scope = household.income_sources
          scope = scope.lock if lock
          scope
        end

        def source_snapshot(source, lock: false, additional_label: nil, additional_type: nil)
          entries = source.income_schedule_entries.order(:effective_on, :entry_type, :id)
          entries = entries.lock if lock
          label = additional_label.to_s.squish.presence || source.label
          type = additional_type.to_s.presence || source.source_type
          conflicts = household.income_sources
            .where(active: true)
            .where(source_type: type)
            .where("LOWER(label) = ?", label.downcase)
            .where.not(id: source.id)
          conflicts = conflicts.lock if lock
          {
            source: source_attributes(source),
            schedule_entries: entries.map { |entry| entry_attributes(entry) },
            conflicting_source_ids: conflicts.order(:id).pluck(:id)
          }
        end

        def source_attributes(source)
          {
            id: source.id,
            label: source.label,
            source_type: source.source_type,
            amount_cents: source.amount_cents,
            cadence: source.cadence,
            active: source.active,
            starts_on: source.starts_on&.iso8601,
            ends_on: source.ends_on&.iso8601
          }
        end

        def entry_attributes(entry)
          {
            id: entry.id,
            income_source_id: entry.income_source_id,
            entry_type: entry.entry_type,
            label: entry.label,
            amount_cents: entry.amount_cents,
            cadence: entry.cadence,
            effective_on: entry.effective_on.iso8601,
            retained_after_transition: entry.retained_after_transition?
          }
        end

        def verify_income_prediction!(predicted, actual)
          return true if income_semantics(predicted) == income_semantics(actual)

          raise ArgumentError, "The income operation result did not match the reviewed change. Nothing changed."
        end

        def income_semantics(snapshot)
          value = snapshot.deep_stringify_keys
          source = value["source"]
          {
            source: source&.except("id"),
            schedule_entries: Array(value["schedule_entries"]).map { |entry| entry.except("id", "income_source_id") }
              .sort_by { |entry| [ entry["effective_on"].to_s, entry["entry_type"].to_s, entry["label"].to_s, entry["amount_cents"].to_i, entry["cadence"].to_s ] },
            conflicting_source_ids: Array(value["conflicting_source_ids"])
          }
        end

        def stale_message
          INCOME_STALE_MESSAGE
        end
      end
    end
  end
end
