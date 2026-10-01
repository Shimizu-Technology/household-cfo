module HouseholdFinance
  module Operations
    class MiaItemAdapter
      ACTION_KEYS = {
        "create_category" => "budget.category.create",
        "update_category" => "budget.category.update",
        "update_allocation" => "budget.allocation.set",
        "archive_category" => "budget.category.archive",
        "restore_category" => "budget.category.restore",
        "create_income_source" => "income.source.create",
        "update_income_source" => "income.source.update",
        "archive_income_source" => "income.source.archive",
        "restore_income_source" => "income.source.restore",
        "create_income_schedule_entry" => "income.schedule.create",
        "update_income_schedule_entry" => "income.schedule.update",
        "delete_income_schedule_entry" => "income.schedule.delete",
        "create_debt" => "debt.record.create",
        "update_debt" => "debt.record.update",
        "archive_debt" => "debt.record.archive",
        "restore_debt" => "debt.record.restore",
        "update_debt_tracking" => "debt.tracking_mode.update"
      }.freeze

      def self.operation_key(item)
        return item.payload.to_h["entry_id"].to_i.positive? ? "income.schedule.update" : "income.schedule.create" if item.action_type.to_s == "upsert_income_schedule_entry"

        ACTION_KEYS[item.action_type.to_s]
      end

      def self.prepare(household, item, year:)
        key = operation_key(item)
        return unless key

        input = item.payload.to_h.deep_symbolize_keys.merge(year: year)
        Registry.fetch(key).new(household).prepare(input)
      end

      def self.normalized_input(household, item, year:)
        key = operation_key(item) || raise(KeyError, item.action_type.to_s)
        input = item.payload.to_h.deep_symbolize_keys.merge(year: year)
        Registry.fetch(key).new(household).normalized_input(input).deep_stringify_keys
      end
    end
  end
end
