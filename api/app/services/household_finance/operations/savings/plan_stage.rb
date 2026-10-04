module HouseholdFinance
  module Operations
    module Savings
      class PlanStage < Base
        KEY = "savings.plan.stage"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[target_cents expected_plan_version_id], optional: %i[reason financial_baseline_version_id baseline_digest spending_changes])
          context = SavingsChallenge::PlanContext.new(nil, user: user).normalize(input)
          input.merge(context).merge(target_cents: SavingsChallenge::Inputs.money!(input[:target_cents], nullable: true, positive: true),
            expected_plan_version_id: SavingsChallenge::Inputs.id!(input[:expected_plan_version_id], nullable: true),
            reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_plan_version_id].present?))
        end

        def subject_for(input, lock:)
          enrollment_for(input, lock: lock)
        end

        def mutate!(enrollment, input, prepared:)
          check_version!(enrollment.current_accepted_plan_version_id, input[:expected_plan_version_id])
          context = SavingsChallenge::PlanContext.new(enrollment, user: user).normalize(input)
          SavingsChallenge::PlanContext.new(enrollment, user: user).validate!(context)
          enrollment.savings_plan_drafts.create!(created_by_user: user, target_cents: input[:target_cents],
            base_plan_version_id: input[:expected_plan_version_id], reason: input[:reason], **context)
        end

        def planned_record(before, input)
          { savings_enrollment_id: before.fetch("id"), created_by_user_id: user.id, target_cents: input[:target_cents],
            base_plan_version_id: input[:expected_plan_version_id], reason: input[:reason], status: "pending", **input.slice(:financial_baseline_version_id, :baseline_digest, :spending_changes) }
        end
      end
    end
  end
end
