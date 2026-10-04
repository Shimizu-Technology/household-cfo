module HouseholdFinance
  module Operations
    module Savings
      class CheckpointStage < Daily::Base
        KEY = "savings.checkpoint.stage"
        VERSION = 1

        private

        def normalize(input)
          input = normal_ids(input, required: %i[milestone_day expected_version_id expected_head_lock_version],
            optional: %i[reason baseline_version_id plan_version_id plan_correction_accepted final_confirmation_accepted])
          day = SavingsChallenge::Inputs.integer!(input[:milestone_day], minimum: 30, maximum: 90)
          raise ArgumentError, "Choose Day 30, 60 or 90" unless day.in?([ 30, 60, 90 ])
          corrected_plan = SavingsChallenge::Daily::Inputs.boolean!(input.fetch(:plan_correction_accepted, false))
          plan_id = SavingsChallenge::Inputs.id!(input[:plan_version_id], nullable: true)
          raise ArgumentError, "Accept an explained checkpoint plan correction explicitly" unless corrected_plan == plan_id.present?
          input.merge(milestone_day: day, expected_version_id: SavingsChallenge::Inputs.id!(input[:expected_version_id], nullable: true),
            expected_head_lock_version: SavingsChallenge::Inputs.integer!(input[:expected_head_lock_version], minimum: 0),
            reason: SavingsChallenge::Inputs.text!(input[:reason], required: input[:expected_version_id].present? || corrected_plan),
            baseline_version_id: SavingsChallenge::Inputs.id!(input[:baseline_version_id], nullable: true),
            plan_version_id: plan_id, plan_correction_accepted: corrected_plan,
            final_confirmation_accepted: SavingsChallenge::Daily::Inputs.boolean!(input.fetch(:final_confirmation_accepted, false)))
        end

        def subject_for(input, lock:)
          @enrollment = enrollment_for(input, lock: lock)
        end

        def mutate!(_subject, input, prepared:)
          checkpoint = SavingsCheckpoint.find_or_create_by!(savings_enrollment: @enrollment, milestone_day: input[:milestone_day])
          checkpoint.lock!
          check_head!(checkpoint, input)
          snapshot = SavingsChallenge::CheckpointSnapshot.new(@enrollment, milestone_day: checkpoint.milestone_day, previous: checkpoint.current_version,
            plan_version_id: input[:plan_version_id], plan_correction: input[:plan_correction_accepted], baseline_version_id: input[:baseline_version_id],
            final_confirmation: input[:final_confirmation_accepted]).call
          SavingsCheckpointDraft.create!(savings_enrollment: @enrollment, savings_checkpoint: checkpoint, created_by_user: user,
            base_version_id: checkpoint.current_version_id, base_head_lock_version: checkpoint.lock_version,
            snapshot: snapshot, reason: input[:reason])
        end
      end
    end
  end
end
