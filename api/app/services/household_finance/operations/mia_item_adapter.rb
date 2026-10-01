module HouseholdFinance
  module Operations
    class MiaItemAdapter
      ACTION_KEYS = {
        "create_category" => "budget.category.create",
        "update_category" => "budget.category.update",
        "update_allocation" => "budget.allocation.set",
        "archive_category" => "budget.category.archive",
        "restore_category" => "budget.category.restore"
      }.freeze

      def self.prepare(household, item, year:)
        key = ACTION_KEYS[item.action_type.to_s]
        return unless key

        input = item.payload.to_h.deep_symbolize_keys.merge(year: year)
        Registry.fetch(key).new(household).prepare(input)
      end

      def self.normalized_input(household, item, year:)
        key = ACTION_KEYS.fetch(item.action_type.to_s)
        input = item.payload.to_h.deep_symbolize_keys.merge(year: year)
        Registry.fetch(key).new(household).send(:normalize, input).deep_stringify_keys
      end
    end
  end
end
