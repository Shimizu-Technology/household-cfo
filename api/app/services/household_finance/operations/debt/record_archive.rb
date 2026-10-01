require_relative "record_update"

module HouseholdFinance
  module Operations
    module Debt
      class RecordArchive < RecordUpdate
        KEY = "debt.record.archive"

        private

        def normalize(input)
          { debt_id: Integer(input.fetch(:debt_id)) }
        end

        def canonical_snapshot(debt, _input, lock:)
          debt_snapshot(debt)
        end

        def predicted_after(before, _input)
          { debt: before.fetch("debt").except("archived_at").merge("active" => false) }
        end

        def validate_execution!(debt, _input, prepared:, source:)
          raise ArgumentError, "This debt is already archived. Nothing changed." unless debt.active?
        end

        def mutate!(debt, _input, prepared:)
          debt.update!(active: false, archived_at: Time.current)
          debt
        end
      end
    end
  end
end
