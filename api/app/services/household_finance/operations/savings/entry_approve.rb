module HouseholdFinance
  module Operations
    module Savings
      class EntryApprove < Base
        KEY = "savings.entry.approve"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[draft_id accepted expected_draft_lock_version expected_version_id expected_entry_lock_version])
          input.merge(draft_id: SavingsChallenge::Inputs.id!(input[:draft_id]), accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]),
            expected_draft_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_draft_lock_version], minimum: 0),
            expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
            expected_entry_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_entry_lock_version], minimum: 0))
        end

        def subject_for(input, lock:)
          @enrollment = enrollment_for(input, lock: lock)
          draft = SavingsEntryDraft.joins(:savings_entry).where(savings_entries: { savings_enrollment_id: @enrollment.id }).find(input[:draft_id])
          @entry = draft.savings_entry
          @entry.lock! if lock
          draft.lock! if lock
          draft
        end

        def mutate!(draft, input, prepared:)
          raise StaleOperation, stale_message unless draft.status == "pending"
          check_version!(draft.lock_version, input[:expected_draft_lock_version])
          check_version!(@entry.lock_version, input[:expected_entry_lock_version])
          check_version!(draft.base_entry_lock_version, input[:expected_entry_lock_version])
          check_version!(@entry.current_approved_version_id, input[:expected_version_id])
          check_version!(draft.base_version_id, input[:expected_version_id])
          raise ArgumentError, "Future savings promises cannot be approved as actual money set aside" if draft.effective_on > @enrollment.local_today
          previous = @entry.current_approved_version
          version = @entry.savings_entry_versions.create!(savings_enrollment: @enrollment, approved_by_user: user,
            previous_version: previous, version_number: previous ? previous.version_number + 1 : 1,
            approval_sequence: @enrollment.advance_approval_sequence!, signed_cents: draft.signed_cents,
            effective_on: draft.effective_on, funding_source: draft.funding_source, currency: "USD", evidence_supported_cents: 0,
            reason: draft.reason, approved_at: Time.current)
          @entry.update!(current_approved_version: version)
          draft.update!(status: "approved", approved_version: version)
          version
        end

        def planned_record(before, _input)
          { savings_entry_id: before.fetch("savings_entry_id"), savings_enrollment_id: @enrollment.id, approved_by_user_id: user.id,
            previous_version_id: before["base_version_id"], signed_cents: before["signed_cents"], effective_on: before["effective_on"],
            funding_source: before["funding_source"], currency: "USD", evidence_supported_cents: 0, reason: before["reason"] }
        end
      end
    end
  end
end
