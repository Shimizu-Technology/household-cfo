module HouseholdFinance
  module Operations
    module Goal
      class TransitionPolicyUpdate < Operations::Base
        KEY = "goal.transition_policy.update"
        VERSION = 1

        private

        def normalize(input)
          { label: input[:label].to_s.squish.truncate(80, omission: "…").presence }
        end

        def ensure_plan!(_input); end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, _input, lock:)
          scope = household.goals.policy.where(goal_type: "transition").order(:id)
          scope = scope.lock if lock
          { policy: policy_snapshot(scope.first), conflicting_policy_ids: scope.offset(1).pluck(:id) }
        end

        def predicted_after(before, input)
          policy = if input.fetch(:label)
            (before.fetch("policy") || {
              "goal_type" => "transition", "record_kind" => "policy", "priority" => 2,
              "source_type" => "setup", "active" => true
            }).merge("label" => input.fetch(:label), "active" => true)
          end
          { policy: policy, conflicting_policy_ids: before.fetch("conflicting_policy_ids") }
        end

        def validate_execution!(_household, _input, prepared:, source:)
          return if prepared.before_snapshot.fetch("conflicting_policy_ids").empty?

          raise ArgumentError, "Multiple transition goals need review before the primary goal can change. Nothing changed."
        end

        def mutate!(_subject, input, prepared:)
          goal = household.goals.policy.where(goal_type: "transition").order(:id).first
          if input.fetch(:label).blank?
            goal&.destroy!
            return household
          end

          goal ||= household.goals.policy.new(goal_type: "transition")
          goal.update!(
            label: input.fetch(:label), priority: 2, record_kind: "policy",
            source_type: "setup", active: true, archived_at: nil
          )
          goal
        end

        def canonical_after_snapshot(_subject, _input, prepared:)
          canonical_snapshot(household, {}, lock: false)
        end

        def verify_after!(predicted, actual)
          comparable = ->(policy) { policy&.slice("label", "goal_type", "record_kind", "priority", "source_type", "active") }
          return true if comparable.call(predicted.fetch("policy")) == comparable.call(actual.fetch("policy")) &&
            predicted.fetch("conflicting_policy_ids") == actual.fetch("conflicting_policy_ids")

          raise Operations::Runner::InvalidPreparedOperation, "The transition goal did not match the reviewed primary goal. Nothing changed."
        end

        def policy_snapshot(goal)
          return unless goal

          {
            id: goal.id, label: goal.label, goal_type: goal.goal_type, record_kind: goal.record_kind,
            priority: goal.priority, source_type: goal.source_type, active: goal.active?
          }
        end

        def stale_message
          "The transition goal changed since this update was prepared. Prepare a fresh update. Nothing changed."
        end
      end
    end
  end
end
