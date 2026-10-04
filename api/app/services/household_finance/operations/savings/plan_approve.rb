module HouseholdFinance
  module Operations
    module Savings
      class PlanApprove < Base
        KEY = "savings.plan.approve"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[draft_id accepted expected_draft_lock_version expected_plan_version_id])
          input.merge(draft_id: SavingsChallenge::Inputs.id!(input[:draft_id]), accepted: SavingsChallenge::Inputs.accepted!(input[:accepted]),
            expected_draft_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_draft_lock_version], minimum: 0),
            expected_plan_version_id: SavingsChallenge::Inputs.id!(input[:expected_plan_version_id], nullable: true))
        end

        def subject_for(input, lock:)
          @enrollment = enrollment_for(input, lock: lock)
          scope = @enrollment.savings_plan_drafts
          (lock ? scope.lock : scope).find(input[:draft_id])
        end

        def mutate!(draft, input, prepared:)
          raise StaleOperation, stale_message unless draft.status == "pending"
          check_version!(draft.lock_version, input[:expected_draft_lock_version])
          check_version!(@enrollment.current_accepted_plan_version_id, input[:expected_plan_version_id])
          check_version!(draft.base_plan_version_id, input[:expected_plan_version_id])
          context = draft.attributes.symbolize_keys.slice(:financial_baseline_version_id, :baseline_digest, :spending_changes)
          SavingsChallenge::PlanContext.new(@enrollment, user: user).validate!(context)
          previous = @enrollment.current_accepted_plan_version
          version = @enrollment.savings_plan_versions.create!(approved_by_user: user, previous_version: previous,
            version_number: previous ? previous.version_number + 1 : 1, approval_sequence: @enrollment.advance_approval_sequence!,
            target_cents: draft.target_cents, reason: draft.reason, approved_at: Time.current, **context)
          @enrollment.update!(current_accepted_plan_version: version)
          draft.update!(status: "approved", approved_plan_version: version)
          version
        end

        def planned_record(before, _input)
          { savings_enrollment_id: before.fetch("savings_enrollment_id"), approved_by_user_id: user.id,
            previous_version_id: before["base_plan_version_id"], target_cents: before["target_cents"], reason: before["reason"],
            financial_baseline_version_id: before["financial_baseline_version_id"], baseline_digest: before["baseline_digest"], spending_changes: before["spending_changes"] }
        end
      end
    end
  end
end
