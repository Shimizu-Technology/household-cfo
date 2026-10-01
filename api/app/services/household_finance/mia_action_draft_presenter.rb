module HouseholdFinance
  class MiaActionDraftPresenter
    def initialize(draft)
      @draft = draft
    end

    def call
      {
        id: draft.id,
        status: draft.status,
        draft_type: draft.draft_type,
        year: draft.year,
        title: draft.title,
        summary: draft.summary,
        rationale: draft.rationale,
        source_prompt: draft.source_prompt,
        created_at: draft.created_at&.iso8601,
        applied_at: draft.applied_at&.iso8601,
        canceled_at: draft.canceled_at&.iso8601,
        impact: draft.metadata.to_h["impact"],
        setup_coverage_after_apply: setup_coverage_after_apply,
        items: action_items
      }
    end

    private

    attr_reader :draft

    def action_items
      draft.mia_action_items.map do |item|
        {
          id: item.id,
          action_type: item.action_type,
          target_record_type: item.target_record_type,
          target_record_id: item.target_record_id,
          label: item.label,
          description: item.description,
          payload: item.payload,
          before_snapshot: item.before_snapshot,
          after_snapshot: item.after_snapshot,
          operation_key: item.operation_key,
          operation_version: item.operation_version,
          review_fields: review_fields(item)
        }
      end
    end

    def review_fields(item)
      return [] if item.operation_key.blank? || item.prepared_operation.blank?

      prepared = item.prepared_operation.to_h
      before = prepared.fetch("before_snapshot", {})
      after = prepared.fetch("predicted_after_snapshot", {})
      case item.operation_key
      when "budget.allocation.set"
        before_rows = Array(before["allocations"]).index_by { |row| row["id"] }
        Array(after["allocations"]).map do |row|
          previous = before_rows.fetch(row["id"], {})
          {
            label: "#{month_label(row["month"])} planned amount",
            before: money_from_cents(previous["planned_amount_cents"]),
            after: money_from_cents(row["planned_amount_cents"])
          }
        end
      when "budget.category.create"
        category = after.fetch("category", {})
        normalized_input = prepared.fetch("normalized_input", {})
        [
          { label: "Category", before: "Does not exist", after: category["name"].to_s },
          { label: "Expense stack", before: "—", after: stack_label(category["stack_key"]) },
          { label: "Planned amount", before: "$0.00", after: money_from_cents(normalized_input["monthly_amount_cents"]) }
        ]
      else
        category_before = before.fetch("category", {})
        category_after = after.fetch("category", {})
        fields = []
        fields << { label: "Category name", before: category_before["name"].to_s, after: category_after["name"].to_s } if category_before["name"] != category_after["name"]
        if category_before["stack_key"] != category_after["stack_key"]
          fields << { label: "Expense stack", before: stack_label(category_before["stack_key"]), after: stack_label(category_after["stack_key"]) }
        end
        if category_before["active"] != category_after["active"]
          fields << { label: "Budget status", before: category_before["active"] ? "Active" : "Archived", after: category_after["active"] ? "Active" : "Archived" }
        end
        fields
      end
    end

    def money_from_cents(value)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(value.to_i), precision: 2)
    end

    def month_label(value)
      AnnualBudgetManager::MONTH_NAMES.fetch(value.to_i - 1, "Month #{value}")
    end

    def stack_label(key)
      SnapshotBuilder::STACK_LABELS.fetch(key.to_s, key.to_s.humanize)
    end

    def setup_coverage_after_apply
      return unless draft.draft_type == "household_setup"

      proposed_values = draft.mia_action_items.each_with_object({}) do |item, values|
        next unless item.action_type == "update_setup_value"

        payload = item.payload.to_h
        values[payload["key"]] = payload["value"]
      end
      SetupStatus.new(
        draft.household,
        additional_confirmed_fields: proposed_values.keys,
        proposed_values: proposed_values
      ).as_json
    end
  end
end
