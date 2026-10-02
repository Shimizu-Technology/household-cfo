module HouseholdFinance
  class MiaActionDraftCanceler
    Result = Struct.new(:success?, :draft, :application, :errors, :replayed?, :conflict?, keyword_init: true)

    def initialize(draft, user:)
      @draft = draft
      @household = draft.household
      @user = user
    end

    def call(idempotency_key: nil)
      key = normalized_key(idempotency_key)
      application = nil

      ApplicationRecord.transaction do
        household.lock!
        draft.lock!
        ensure_actor_membership!
        items = draft.mia_action_items.lock.order(:position, :id).to_a
        existing = household.mia_action_draft_applications.find_by(user: user, idempotency_key: key)
        return replay(existing, request_fingerprint(Array(existing.selected_item_ids))) if existing
        remaining_ids = items.reject { |item| item.applied_at.present? || item.canceled_at.present? }.map(&:id)
        fingerprint = request_fingerprint(remaining_ids)
        raise ArgumentError, "Mia action draft is not available for cancelation" unless draft.reviewable?

        application = household.mia_action_draft_applications.create!(
          mia_action_draft: draft,
          user: user,
          idempotency_key: key,
          request_kind: "cancel",
          request_fingerprint: fingerprint,
          selected_item_ids: remaining_ids
        )
        canceled_at = Time.current
        items.each do |item|
          next if item.applied_at.present? || item.canceled_at.present?

          item.update!(canceled_at: canceled_at, canceled_by_user: user)
        end
        draft.update!(status: "canceled", canceled_by_user: user, canceled_at: canceled_at)
        audit!(remaining_ids)
        application.update!(
          status: "completed",
          completed_at: Time.current,
          response_payload: { draft_id: draft.id, draft_status: "canceled", canceled_item_ids: remaining_ids }
        )
      end

      Result.new(success?: true, draft: draft.reload, application: application.reload, errors: [], replayed?: false)
    rescue Operations::Runner::IdempotencyConflict => e
      Result.new(success?: false, draft: draft, application: nil, errors: [ e.message ], conflict?: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, draft: draft, application: nil, errors: e.record.errors.full_messages)
    rescue ArgumentError => e
      Result.new(success?: false, draft: draft, application: nil, errors: [ e.message ])
    end

    private

    attr_reader :draft, :household, :user

    def normalized_key(value)
      key = value.to_s.strip.presence || "legacy-mia-cancel:#{draft.id}:#{user.id}"
      raise ArgumentError, "Idempotency key is too long" if key.length > 200
      key
    end

    def request_fingerprint(item_ids)
      Digest::SHA256.hexdigest(
        { request_kind: "cancel", household_id: household.id, draft_id: draft.id, user_id: user.id, item_ids: item_ids }.to_json
      )
    end

    def replay(application, fingerprint)
      unless secure_equal?(application.request_fingerprint, fingerprint)
        raise Operations::Runner::IdempotencyConflict,
          "That idempotency key was already used for a different Mia plan request. Nothing changed."
      end
      raise ArgumentError, "That Mia plan cancellation is still processing. Try again shortly." unless application.status == "completed"

      Result.new(success?: true, draft: draft.reload, application: application, errors: [], replayed?: true)
    end

    def ensure_actor_membership!
      membership = household.household_memberships.lock.find_by(user_id: user.id)
      return if membership&.role.in?(%w[owner partner])

      raise ArgumentError, "You no longer have permission to change this household. Nothing changed."
    end

    def secure_equal?(left, right)
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def audit!(item_ids)
      household.household_audit_events.create!(
        user: user,
        actor_type: "user",
        event_type: "mia_action_draft.canceled",
        auditable_type: "MiaActionDraft",
        auditable_id: draft.id,
        occurred_at: Time.current,
        metadata: {
          draft_id: draft.id,
          title: draft.title,
          canceled_item_ids: item_ids
        }
      )
    end
  end
end
