require_relative "base"

module HouseholdFinance
  module Operations
    module Goal
      class RecordUpdate < Base
        KEY = "goal.record.update"
        VERSION = 1

        private

        def normalize(input)
          values = { goal_id: Integer(input.fetch(:goal_id)) }
          values[:label] = normalized_label(input[:label]) if input.key?(:label)
          values[:goal_type] = normalized_type(input[:goal_type]) if input.key?(:goal_type)
          values.merge!(normalize_optional_money(input, :target_amount, :target_amount_cents, :target_amount_known, label: "Target amount")) if input.key?(:target_amount) || input.key?(:target_amount_cents)
          values.merge!(normalize_optional_money(input, :current_amount, :current_amount_cents, :current_amount_known, label: "Current progress")) if input.key?(:current_amount) || input.key?(:current_amount_cents)
          values[:target_on] = normalize_target_on(input[:target_on]) if input.key?(:target_on)
          values[:priority] = Integer(input[:priority]) if input.key?(:priority)
          raise ArgumentError, "Choose at least one goal field to update" if values.one?
          values
        end

        def subject_for(input, lock:)
          goal_scope(lock: lock).find(input.fetch(:goal_id))
        end

        def canonical_snapshot(goal, input, lock:)
          goal_snapshot(goal).merge(conflicting_goal_ids: conflict_ids(label: input[:label] || goal.label, goal_type: input[:goal_type] || goal.goal_type, excluding_id: goal.id, lock: lock))
        end

        def predicted_after(before, input)
          { goal: before.fetch("goal").merge(input.except(:goal_id).stringify_keys), conflicting_goal_ids: before.fetch("conflicting_goal_ids") }
        end

        def validate_execution!(goal, _input, prepared:, source:)
          raise ArgumentError, "Restore this goal before editing it. Nothing changed." unless goal.active?
          raise ArgumentError, "An active goal already uses that name and type. Nothing changed." if prepared.before_snapshot.fetch("conflicting_goal_ids").any?
        end

        def mutate!(goal, input, prepared:)
          goal.update!(input.except(:goal_id))
          goal
        end

        def canonical_after_snapshot(goal, _input, prepared:)
          goal_snapshot(goal.reload)
        end

        def verify_after!(predicted, actual)
          verify_goal_prediction!(predicted, actual)
        end
      end
    end
  end
end
