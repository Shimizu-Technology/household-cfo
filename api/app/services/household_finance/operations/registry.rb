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
          Goal::RunwayPolicyUpdate::KEY => Goal::RunwayPolicyUpdate,
          Goal::TransitionPolicyUpdate::KEY => Goal::TransitionPolicyUpdate,
          Profile::HouseholdUpdate::KEY => Profile::HouseholdUpdate,
          Profile::SetupConfirmationUpdate::KEY => Profile::SetupConfirmationUpdate,
          Transaction::DraftCreate::KEY => Transaction::DraftCreate,
          Transaction::DraftUpdate::KEY => Transaction::DraftUpdate,
          Transaction::DraftConfirm::KEY => Transaction::DraftConfirm,
          Transaction::DraftIgnore::KEY => Transaction::DraftIgnore,
          Transaction::DraftMatch::KEY => Transaction::DraftMatch,
          Transaction::DraftReopen::KEY => Transaction::DraftReopen,
          Transaction::DraftsBulkIgnore::KEY => Transaction::DraftsBulkIgnore,
          Transaction::DraftsBulkConfirm::KEY => Transaction::DraftsBulkConfirm,
          SourceReview::DraftStage::KEY => SourceReview::DraftStage,
          SourceReview::DraftApprove::KEY => SourceReview::DraftApprove,
          SourceReview::DraftCancel::KEY => SourceReview::DraftCancel,
          SourceReview::AccountLink::KEY => SourceReview::AccountLink,
          SourceReview::RevisionApprove::KEY => SourceReview::RevisionApprove,
          SourceReview::EconomicLink::KEY => SourceReview::EconomicLink,
          SourceReview::ExpenseProject::KEY => SourceReview::ExpenseProject,
          Savings::EnrollmentAccept::KEY => Savings::EnrollmentAccept,
          Savings::PlanStage::KEY => Savings::PlanStage,
          Savings::PlanApprove::KEY => Savings::PlanApprove,
          Savings::EntryStage::KEY => Savings::EntryStage,
          Savings::EntryApprove::KEY => Savings::EntryApprove,
          Savings::ZeroAttest::KEY => Savings::ZeroAttest,
          Baseline::Approve::KEY => Baseline::Approve,
          Baseline::Revise::KEY => Baseline::Revise,
          Privacy::ConsentSet::KEY => Privacy::ConsentSet,
          Privacy::SupportRequestCreate::KEY => Privacy::SupportRequestCreate,
          Privacy::SupportAccessGrant::KEY => Privacy::SupportAccessGrant,
          Privacy::SupportAccessRevoke::KEY => Privacy::SupportAccessRevoke,
          Privacy::SourceUseAuthorize::KEY => Privacy::SourceUseAuthorize,
          Privacy::SourceUseRevoke::KEY => Privacy::SourceUseRevoke,
          Savings::Daily::PurchaseStage::KEY => Savings::Daily::PurchaseStage,
          Savings::Daily::PurchaseApprove::KEY => Savings::Daily::PurchaseApprove,
          Savings::Daily::ReflectionSave::KEY => Savings::Daily::ReflectionSave,
          Savings::Daily::ReflectionErase::KEY => Savings::Daily::ReflectionErase,
          Savings::Daily::CheckInSave::KEY => Savings::Daily::CheckInSave,
          Savings::CheckpointStage::KEY => Savings::CheckpointStage,
          Savings::CheckpointApprove::KEY => Savings::CheckpointApprove,
          Savings::Daily::CategoryCreate::KEY => Savings::Daily::CategoryCreate,
          Reminders::PreferenceSet::KEY => Reminders::PreferenceSet,
          Reminders::Dismiss::KEY => Reminders::Dismiss,
          Savings::Evidence::Attach::KEY => Savings::Evidence::Attach,
          Savings::Evidence::Revoke::KEY => Savings::Evidence::Revoke,
          Savings::Debt::Stage::KEY => Savings::Debt::Stage,
          Savings::Debt::Approve::KEY => Savings::Debt::Approve
        }
      end
    end
  end
end
