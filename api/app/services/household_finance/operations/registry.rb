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
          Debt::RecordCreate::KEY => Debt::RecordCreate,
          Debt::RecordUpdate::KEY => Debt::RecordUpdate,
          Debt::RecordArchive::KEY => Debt::RecordArchive,
          Debt::RecordRestore::KEY => Debt::RecordRestore,
          Debt::TrackingModeUpdate::KEY => Debt::TrackingModeUpdate,
          Account::RecordCreate::KEY => Account::RecordCreate,
          Account::RecordUpdate::KEY => Account::RecordUpdate,
          Account::RecordArchive::KEY => Account::RecordArchive,
          Account::RecordRestore::KEY => Account::RecordRestore,
          Account::PlaidLink::KEY => Account::PlaidLink,
          Account::PlaidReconcile::KEY => Account::PlaidReconcile,
          Account::PlaidUnlink::KEY => Account::PlaidUnlink,
          Goal::RecordCreate::KEY => Goal::RecordCreate,
          Goal::RecordUpdate::KEY => Goal::RecordUpdate,
          Goal::RecordArchive::KEY => Goal::RecordArchive,
          Goal::RecordRestore::KEY => Goal::RecordRestore,
          Transaction::DraftCreate::KEY => Transaction::DraftCreate,
          Transaction::DraftUpdate::KEY => Transaction::DraftUpdate,
          Transaction::DraftConfirm::KEY => Transaction::DraftConfirm,
          Transaction::DraftIgnore::KEY => Transaction::DraftIgnore,
          Transaction::DraftMatch::KEY => Transaction::DraftMatch,
          Transaction::DraftReopen::KEY => Transaction::DraftReopen,
          Transaction::DraftsBulkIgnore::KEY => Transaction::DraftsBulkIgnore,
          Transaction::DraftsBulkConfirm::KEY => Transaction::DraftsBulkConfirm
        }
      end
    end
  end
end
