module HouseholdFinance
  module Operations
    module Goal
      class Base < Operations::Base
        private

        def ensure_plan!(_input); end

        def stale_message
          "Goal details changed since this review was prepared. Prepare a fresh review. Nothing changed."
        end

        def normalized_label(value)
          label = value.to_s.squish.truncate(120, omission: "…")
          raise ArgumentError, "Goal name is required" if label.blank?
          label
        end

        def normalized_type(value)
          value.to_s.presence_in(::Goal::TRACKED_GOAL_TYPES) || raise(ArgumentError, "Choose a valid goal type")
        end

        def normalize_optional_money(input, value_key, cents_key, known_key, label:)
          if input.key?(value_key)
            value = input[value_key]
            return { known_key => false, cents_key => 0 } if value.nil? || value.to_s.strip.blank? || value.to_s.casecmp("unknown").zero?
            return { known_key => true, cents_key => Money.cents!(value, message: "#{label} must be a number with no more than two decimal places") }
          end
          return {} unless input.key?(cents_key)
          raise ArgumentError, "#{label} known flag is required with cents" unless input.key?(known_key)
          known = input.fetch(known_key)
          raise ArgumentError, "#{label} known flag must be true or false" unless known == true || known == false
          cents = Integer(input.fetch(cents_key))
          raise ArgumentError, "#{label} cannot be negative" if cents.negative?
          { known_key => known, cents_key => known ? cents : 0 }
        end

        def normalize_target_on(value)
          return nil if value.nil? || value.to_s.strip.blank?
          Date.iso8601(value.to_s).iso8601
        rescue Date::Error
          raise ArgumentError, "Target date must be a valid date"
        end

        def goal_scope(lock:)
          scope = household.goals.tracked
          lock ? scope.lock : scope
        end

        def goal_snapshot(goal)
          {
            goal: {
              id: goal.id, label: goal.label, goal_type: goal.goal_type,
              target_amount_cents: goal.target_amount_cents, target_amount_known: goal.target_amount_known?,
              current_amount_cents: goal.current_amount_cents, current_amount_known: goal.current_amount_known?,
              target_on: goal.target_on&.iso8601, priority: goal.priority,
              active: goal.active?, archived_at: goal.archived_at&.iso8601,
              source_type: goal.source_type, source_metadata: goal.source_metadata,
              record_kind: goal.record_kind
            }
          }
        end

        def conflict_ids(label:, goal_type:, excluding_id: nil, lock: false)
          scope = household.goals.tracked.active.where(goal_type: goal_type).where("LOWER(label) = ?", label.downcase)
          scope = scope.where.not(id: excluding_id) if excluding_id
          scope = scope.lock if lock
          scope.order(:id).pluck(:id)
        end

        def verify_goal_prediction!(predicted, actual)
          expected = predicted.fetch("goal")
          observed = actual.fetch("goal")
          return true if expected == observed.slice(*expected.keys)
          raise Operations::Runner::InvalidPreparedOperation, "The saved goal did not match the reviewed change. Nothing changed."
        end
      end
    end
  end
end
