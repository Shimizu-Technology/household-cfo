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
          Budget::AllocationSet::KEY => Budget::AllocationSet,
          Income::SourceCreate::KEY => Income::SourceCreate,
          Income::SourceUpdate::KEY => Income::SourceUpdate,
          Income::SourceArchive::KEY => Income::SourceArchive,
          Income::SourceRestore::KEY => Income::SourceRestore,
          Income::ScheduleCreate::KEY => Income::ScheduleCreate,
          Income::ScheduleUpdate::KEY => Income::ScheduleUpdate,
          Income::ScheduleDelete::KEY => Income::ScheduleDelete,
          Transaction::DraftCreate::KEY => Transaction::DraftCreate,
          Transaction::DraftUpdate::KEY => Transaction::DraftUpdate,
          Transaction::DraftIgnore::KEY => Transaction::DraftIgnore,
          Transaction::DraftsBulkIgnore::KEY => Transaction::DraftsBulkIgnore
        }
      end
    end
  end
end
