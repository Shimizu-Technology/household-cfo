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
          after_snapshot: item.after_snapshot
        }
      end
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
