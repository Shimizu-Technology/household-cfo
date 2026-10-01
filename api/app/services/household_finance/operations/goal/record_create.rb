require_relative "base"

module HouseholdFinance
  module Operations
    module Goal
      class RecordCreate < Base
        KEY = "goal.record.create"
        VERSION = 1

        private

        def normalize(input)
          values = {
            label: normalized_label(input[:label]),
            goal_type: normalized_type(input[:goal_type].presence || "other"),
            target_on: normalize_target_on(input[:target_on]),
            source_type: input[:source_type].to_s.presence_in(::Goal::SOURCE_TYPES) || "manual_ui",
            source_metadata: input[:source_metadata].is_a?(Hash) ? input[:source_metadata].slice("document_import_id", "document_import_item_id") : {}
          }
          values.merge!(normalize_optional_money(input, :target_amount, :target_amount_cents, :target_amount_known, label: "Target amount"))
          values.merge!(normalize_optional_money(input, :current_amount, :current_amount_cents, :current_amount_known, label: "Current progress"))
          values[:target_amount_known] = false unless values.key?(:target_amount_known)
          values[:target_amount_cents] = 0 unless values.key?(:target_amount_cents)
          values[:current_amount_known] = false unless values.key?(:current_amount_known)
          values[:current_amount_cents] = 0 unless values.key?(:current_amount_cents)
          values[:priority] = Integer(input[:priority]) if input[:priority].present?
          values
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          {
            goal: nil,
            conflicting_goal_ids: conflict_ids(label: input[:label], goal_type: input[:goal_type], lock: lock),
            next_priority: household.goals.tracked.maximum(:priority).to_i + 1
          }
        end

        def predicted_after(before, input)
          goal = input.slice(:label, :goal_type, :target_amount_cents, :target_amount_known, :current_amount_cents, :current_amount_known, :target_on, :source_type, :source_metadata)
            .merge(priority: input[:priority] || before.fetch("next_priority"), active: true, archived_at: nil, record_kind: "tracked")
          { goal: goal, conflicting_goal_ids: before.fetch("conflicting_goal_ids"), next_priority: before.fetch("next_priority") }
        end

        def validate_execution!(_household, _input, prepared:, source:)
          raise ArgumentError, "An active goal already uses that name and type. Edit it or choose a different name. Nothing changed." if prepared.before_snapshot.fetch("conflicting_goal_ids").any?
        end

        def mutate!(_household, input, prepared:)
          household.goals.create!(input.merge(priority: input[:priority] || prepared.before_snapshot.fetch("next_priority"), record_kind: "tracked", active: true, archived_at: nil))
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
