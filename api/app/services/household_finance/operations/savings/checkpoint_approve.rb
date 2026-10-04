module HouseholdFinance
  module Operations
    module Savings
      class CheckpointApprove < Daily::Base
        KEY = "savings.checkpoint.approve"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[draft_id accepted expected_draft_lock_version expected_version_id expected_head_lock_version])
          input.merge(draft_id: SavingsChallenge::Inputs.id!(input[:draft_id]), accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]),
            expected_draft_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_draft_lock_version], minimum: 0),
            expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
            expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0))
        end

        def subject_for(input, lock:)
          @enrollment = enrollment_for(input, lock: lock)
          draft = SavingsCheckpointDraft.where(savings_enrollment: @enrollment).find(input[:draft_id])
          @checkpoint = draft.savings_checkpoint
          @checkpoint.lock! if lock
          draft.lock! if lock
          draft
        end

        def mutate!(draft, input, prepared:)
          raise StaleOperation, stale_message unless draft.status == "pending"
          check_head!(@checkpoint, input)
          check_version!(draft.lock_version, input[:expected_draft_lock_version])
          check_version!(draft.base_version_id, input[:expected_version_id])
          check_version!(draft.base_head_lock_version, input[:expected_head_lock_version])
          raise ArgumentError, "Future milestones cannot be approved" if Date.iso8601(draft.snapshot.fetch("cutoff_on")) > @enrollment.local_today
          check_version!(@enrollment.approval_sequence, draft.snapshot.fetch("financial_approval_sequence"))
          check_version!(ledger(@enrollment, lock: true).sequence, draft.snapshot.fetch("daily_approval_sequence"))
          baseline = SavingsChallenge::CheckpointBaseline.resolve!(enrollment: @enrollment, version_id: draft.snapshot.dig("baseline", "version_id"))
          raise StaleOperation, stale_message unless baseline == draft.snapshot["baseline"]
          SavingsChallenge::CheckpointSnapshot.validate!(enrollment: @enrollment, checkpoint: @checkpoint, snapshot: draft.snapshot, previous: @checkpoint.current_version)
          version = SavingsCheckpointVersion.create!(version_attributes(@checkpoint, reason: draft.reason).merge(savings_checkpoint: @checkpoint, snapshot: draft.snapshot))
          @checkpoint.update!(current_version: version)
          draft.update!(status: "approved", approved_version: version)
          version
        end
      end
    end
  end
end
