require_relative "record_update"

module HouseholdFinance
  module Operations
    module Goal
      class RecordArchive < RecordUpdate
        KEY = "goal.record.archive"
        private
        def normalize(input)
          { goal_id: Integer(input.fetch(:goal_id)) }
        end
        def canonical_snapshot(goal, _input, lock:)
          goal_snapshot(goal)
        end
        def predicted_after(before, _input)
          { goal: before.fetch("goal").except("archived_at").merge("active" => false) }
        end
        def validate_execution!(goal, _input, prepared:, source:)
          raise ArgumentError, "This goal is already archived. Nothing changed." unless goal.active?
        end
        def mutate!(goal, _input, prepared:)
          goal.update!(active: false, archived_at: Time.current)
          goal
        end
      end
    end
  end
end
