require_relative "record_update"

module HouseholdFinance
  module Operations
    module Debt
      class RecordRestore < RecordUpdate
        KEY = "debt.record.restore"

        private

        def normalize(input)
          { debt_id: Integer(input.fetch(:debt_id)) }
        end

        def canonical_snapshot(debt, _input, lock:)
          debt_snapshot(debt).merge(conflicting_debt_ids: conflict_ids(label: debt.label, debt_type: debt.debt_type, excluding_id: debt.id, lock: lock))
        end

        def predicted_after(before, _input)
          { debt: before.fetch("debt").merge("active" => true, "archived_at" => nil), conflicting_debt_ids: before.fetch("conflicting_debt_ids") }
        end

        def validate_execution!(debt, _input, prepared:, source:)
          raise ArgumentError, "This debt is already active. Nothing changed." if debt.active?
          if prepared.before_snapshot.fetch("conflicting_debt_ids").any?
            raise ArgumentError, "An active debt already uses that name and type. Rename it before restoring this record. Nothing changed."
          end
        end

        def mutate!(debt, _input, prepared:)
          debt.update!(active: true, archived_at: nil)
          debt
        end
      end
    end
  end
end
