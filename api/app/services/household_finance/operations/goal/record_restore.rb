require_relative "record_update"

module HouseholdFinance
  module Operations
    module Goal
      class RecordRestore < RecordUpdate
        KEY = "goal.record.restore"
        private
        def normalize(input)
          { goal_id: Integer(input.fetch(:goal_id)) }
        end
        def canonical_snapshot(goal, _input, lock:)
          goal_snapshot(goal).merge(conflicting_goal_ids: conflict_ids(label: goal.label, goal_type: goal.goal_type, excluding_id: goal.id, lock: lock))
        end
        def predicted_after(before, _input)
          { goal: before.fetch("goal").merge("active" => true, "archived_at" => nil), conflicting_goal_ids: before.fetch("conflicting_goal_ids") }
        end
        def validate_execution!(goal, _input, prepared:, source:)
          raise ArgumentError, "This goal is already active. Nothing changed." if goal.active?
          raise ArgumentError, "An active goal already uses that name and type. Rename it before restoring this record. Nothing changed." if prepared.before_snapshot.fetch("conflicting_goal_ids").any?
        end
        def mutate!(goal, _input, prepared:)
          goal.update!(active: true, archived_at: nil)
          goal
        end
      end
    end
  end
end
