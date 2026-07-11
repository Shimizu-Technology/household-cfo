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
  end
end
