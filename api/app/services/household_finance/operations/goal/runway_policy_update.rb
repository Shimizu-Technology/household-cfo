module HouseholdFinance
  module Operations
    module Goal
      class RunwayPolicyUpdate < Operations::Base
        KEY = "goal.runway_policy.update"
        VERSION = 1

        private

        def normalize(input)
          months = BigDecimal(input.fetch(:target_months).to_s)
          unless months.finite? && months.positive? && months <= 120
            raise ArgumentError, "Runway target must be greater than 0 and no more than 120 months"
          end

          { target_months: months.to_s("F") }
        rescue ArgumentError
          raise ArgumentError, "Runway target must be greater than 0 and no more than 120 months"
        end

        def ensure_plan!(_input); end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, _input, lock:)
          scope = household.goals.policy.where(goal_type: "runway").order(:id)
          scope = scope.lock if lock
          { policy: policy_snapshot(scope.first), conflicting_policy_ids: scope.offset(1).pluck(:id) }
        end

        def predicted_after(before, input)
          policy = before.fetch("policy") || {
            "label" => "Runway target", "goal_type" => "runway", "record_kind" => "policy",
            "priority" => 1, "source_type" => "mia", "active" => true
          }
          { policy: policy.merge("target_months" => input.fetch(:target_months)), conflicting_policy_ids: before.fetch("conflicting_policy_ids") }
        end

        def validate_execution!(_household, _input, prepared:, source:)
          return if prepared.before_snapshot.fetch("conflicting_policy_ids").empty?

          raise ArgumentError, "Multiple runway policies need review before this target can change. Nothing changed."
        end

        def mutate!(_subject, input, prepared:)
          goal = household.goals.policy.where(goal_type: "runway").order(:id).first_or_initialize
          goal.update!(
            label: "Runway target", target_months: BigDecimal(input.fetch(:target_months)), priority: 1,
            record_kind: "policy", source_type: goal.persisted? ? goal.source_type : "mia", active: true, archived_at: nil
          )
          goal
        end

        def canonical_after_snapshot(goal, _input, prepared:)
          { policy: policy_snapshot(goal.reload), conflicting_policy_ids: prepared.before_snapshot.fetch("conflicting_policy_ids") }
        end

        def verify_after!(predicted, actual)
          comparable_fields = %w[label goal_type record_kind target_months priority source_type active]
          predicted_policy = predicted.fetch("policy").slice(*comparable_fields)
          actual_policy = actual.fetch("policy").slice(*comparable_fields)
          return true if predicted_policy == actual_policy &&
            predicted.fetch("conflicting_policy_ids") == actual.fetch("conflicting_policy_ids")

          raise Operations::Runner::InvalidPreparedOperation, "The runway policy did not match the reviewed target. Nothing changed."
        end

        def policy_snapshot(goal)
          return unless goal

          {
            id: goal.id, label: goal.label, goal_type: goal.goal_type, record_kind: goal.record_kind,
            target_months: goal.target_months.to_d.to_s("F"), priority: goal.priority,
            source_type: goal.source_type, active: goal.active?
          }
        end

        def stale_message
          "The runway policy changed since Mia prepared this review. Ask Mia to draft a fresh target. Nothing changed."
        end
      end
    end
  end
end
