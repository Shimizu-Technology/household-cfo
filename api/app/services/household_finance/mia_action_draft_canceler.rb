module HouseholdFinance
  class MiaActionDraftCanceler
    Result = Struct.new(:success?, :draft, :errors, keyword_init: true)

    def initialize(draft, user:)
      @draft = draft
      @user = user
    end

    def call
      ApplicationRecord.transaction do
        draft.with_lock do
          raise ArgumentError, "Mia action draft is not pending" unless draft.pending?

          draft.update!(status: "canceled", canceled_by_user: user, canceled_at: Time.current)
          audit!
        end
      end

      Result.new(success?: true, draft: draft.reload, errors: [])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, errors: e.record.errors.full_messages)
    rescue ArgumentError => e
      Result.new(success?: false, draft: draft, errors: [ e.message ])
    end

    private

    attr_reader :draft, :user

    def audit!
      draft.household.household_audit_events.create!(
        user: user,
        actor_type: "user",
        event_type: "mia_action_draft.canceled",
        auditable_type: "MiaActionDraft",
        auditable_id: draft.id,
        occurred_at: Time.current,
        metadata: {
          draft_id: draft.id,
          title: draft.title,
          item_count: draft.mia_action_items.size
        }
      )
    end
  end
end
