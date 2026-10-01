module HouseholdFinance
  module Operations
    class Registry
      class UnknownOperation < ArgumentError; end

      def self.fetch(key, version = nil)
        operation = operations.fetch(key.to_s) { raise UnknownOperation, "Unsupported household operation" }
        if version.present? && operation::VERSION != version.to_i
          raise UnknownOperation, "Unsupported household operation version"
        end
        operation
      end

      def self.operations
        {
          Budget::CategoryCreate::KEY => Budget::CategoryCreate,
          Budget::CategoryUpdate::KEY => Budget::CategoryUpdate,
          Budget::CategoryArchive::KEY => Budget::CategoryArchive,
          Budget::CategoryRestore::KEY => Budget::CategoryRestore,
          Budget::AllocationSet::KEY => Budget::AllocationSet
        }
      end
    end
  end
end
