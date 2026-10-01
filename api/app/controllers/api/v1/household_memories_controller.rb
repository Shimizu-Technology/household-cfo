module Api
  module V1
    class HouseholdMemoriesController < BaseController
      before_action :authenticate_user!
      before_action :require_memory_participant!
      before_action :require_writable_household!, except: :index
      before_action :require_personalization_active!, only: %i[update confirm]
      before_action :set_memory, only: %i[update destroy confirm reject]

      def index
        expire_stale_memories
        render json: memory_payload
      end

      def create
        request_key = memory_params[:request_key].presence
        attributes = normalized_create_attributes
        if request_key && (existing = current_household.household_memories.find_by(owner_user: current_user, request_key: request_key))
          return render_create_replay(existing, attributes)
        end
        return render_personalization_paused if personalization_paused?
        if current_household.household_memories.where(owner_user: current_user).count >= HouseholdMemory::MAX_STORED_PER_OWNER
          return render json: { errors: [ "You can keep up to #{HouseholdMemory::MAX_STORED_PER_OWNER} Mia memories. Forget one before adding another." ] }, status: :unprocessable_entity
        end

        memory = persist_household_memory!(
          attributes.merge(
            owner_user: current_user,
            request_key: request_key,
            confirmed_at: attributes.fetch(:status) == "user_confirmed" ? Time.current : nil,
            source_kind: "manual_profile"
          )
        )
        audit("mia_memory.created", memory)
        render json: { memory: memory.as_api_json(viewer: current_user), personalization: personalization_payload }, status: :created
      rescue ActiveRecord::RecordNotUnique
        raise if request_key.blank?

        existing = current_household.household_memories.find_by(owner_user: current_user, request_key: request_key)
        raise unless existing

        render_create_replay(existing.reload, attributes)
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def update
        return render_not_owner unless @memory.owner_user_id == current_user.id

        attributes = memory_params.to_h.symbolize_keys.except(:request_key, :confirmed)
        attributes[:visibility] ||= "private"
        @memory.assign_attributes(attributes)
        material_change = @memory.will_save_change_to_display_value? || @memory.will_save_change_to_category? ||
          @memory.will_save_change_to_sensitivity? || @memory.will_save_change_to_visibility?
        if material_change && @memory.sensitivity == "sensitive"
          attributes[:status] = "pending_confirmation"
          attributes[:confirmed_at] = nil
          attributes[:rejected_at] = nil
        elsif material_change && @memory.status.in?(%w[rejected expired])
          attributes[:status] = "user_confirmed"
          attributes[:confirmed_at] = Time.current
          attributes[:rejected_at] = nil
        end
        @memory.assign_attributes(attributes)
        if @memory.changed?
          @memory.save!
          audit("mia_memory.updated", @memory)
        end
        render json: { memory: @memory.as_api_json(viewer: current_user), personalization: personalization_payload }
      rescue ActiveRecord::RecordInvalid => error
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def confirm
        return render_not_owner unless @memory.owner_user_id == current_user.id
        unless @memory.status == "user_confirmed"
          @memory.update!(status: "user_confirmed", confirmed_at: Time.current, rejected_at: nil)
          audit("mia_memory.confirmed", @memory)
        end
        render json: { memory: @memory.as_api_json(viewer: current_user), personalization: personalization_payload }
      end

      def reject
        return render_not_owner unless @memory.owner_user_id == current_user.id
        unless @memory.status == "rejected"
          @memory.update!(status: "rejected", rejected_at: Time.current, confirmed_at: nil)
          audit("mia_memory.rejected", @memory)
        end
        render json: { memory: @memory.as_api_json(viewer: current_user), personalization: personalization_payload }
      end

      def destroy
        return render_not_owner unless @memory.owner_user_id == current_user.id
        memory_id = @memory.id
        @memory.destroy!
        current_household.household_audit_events.create!(
          user: current_user, actor_type: "user", event_type: "mia_memory.forgotten",
          occurred_at: Time.current, metadata: { memory_id: memory_id }
        )
        head :no_content
      end

      private

      def memory_params
        params.require(:memory).permit(
          :category, :display_value, :sensitivity, :visibility, :expires_at,
          :request_key, :confirmed, structured_value: {}
        )
      end

      def set_memory
        @memory = current_household.household_memories.visible_to(current_user).find(params[:id])
      end

      def require_memory_participant!
        membership = current_household.household_memberships.find_by(user_id: current_user.id)
        return if membership&.role.in?(%w[owner partner])
        render json: { errors: [ "Mia memory is private to household participants." ] }, status: :forbidden
      end

      def normalized_create_attributes
        raw = memory_params.to_h.symbolize_keys
        sensitivity = raw[:sensitivity].presence || "ordinary"
        confirmed = ActiveModel::Type::Boolean.new.cast(raw[:confirmed])
        {
          category: raw[:category].to_s,
          display_value: raw[:display_value].to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish,
          sensitivity: sensitivity,
          visibility: "private",
          status: sensitivity == "sensitive" || !confirmed ? "pending_confirmation" : "user_confirmed",
          expires_at: HouseholdMemory.type_for_attribute("expires_at").cast(raw[:expires_at]),
          structured_value: normalized_structured_value(raw[:structured_value]),
          source_kind: "manual_profile"
        }
      end

      def idempotent_create_matches?(memory, attributes)
        memory_create_fingerprint(memory) == attributes
      end

      def memory_create_fingerprint(memory)
        {
          category: memory.category,
          display_value: memory.display_value,
          sensitivity: memory.sensitivity,
          visibility: memory.visibility,
          status: memory.status,
          expires_at: memory.expires_at,
          structured_value: normalized_structured_value(memory.structured_value),
          source_kind: memory.source_kind
        }
      end

      def normalized_structured_value(value)
        JSON.parse(JSON.generate(value.presence || {}))
      end

      def render_create_replay(memory, attributes)
        unless idempotent_create_matches?(memory, attributes)
          return render json: { errors: [ "This memory request ID was already used for different content." ] }, status: :conflict
        end

        render json: { memory: memory.as_api_json(viewer: current_user), personalization: personalization_payload }, status: :ok
      end

      def persist_household_memory!(attributes)
        current_household.household_memories.create!(attributes)
      end

      def personalization_paused?
        current_household.household_memberships.find_by!(user_id: current_user.id).mia_personalization_paused?
      end

      def render_personalization_paused
        render json: { errors: [ "Resume personalization before adding or changing Mia memories." ] }, status: :conflict
      end

      def require_personalization_active!
        render_personalization_paused if personalization_paused?
      end

      def expire_stale_memories
        current_household.household_memories.visible_to(current_user).where.not(status: %w[rejected expired])
          .where(expires_at: ..Time.current).update_all(status: "expired", updated_at: Time.current)
      end

      def personalization_payload
        membership = current_household.household_memberships.find_by!(user_id: current_user.id)
        { paused: membership.mia_personalization_paused?, paused_at: membership.mia_personalization_paused_at&.iso8601 }
      end

      def memory_payload
        {
          memories: current_household.household_memories.visible_to(current_user).includes(:owner_user).ordered.limit(HouseholdMemory::MAX_VISIBLE_LIST).map { |memory| memory.as_api_json(viewer: current_user) },
          personalization: personalization_payload,
          policy: {
            source: "Only memories you explicitly saved appear here. Each household participant has a private memory list.",
            financial_truth: "Mia uses approved household records for financial facts. Memories can only personalize coaching and follow-up.",
            coach_visibility: false
          }
        }
      end

      def audit(event_type, memory)
        current_household.household_audit_events.create!(
          user: current_user, actor_type: "user", event_type: event_type,
          occurred_at: Time.current,
          metadata: { memory_id: memory.id, category: memory.category, visibility: memory.visibility, status: memory.status }
        )
      end

      def render_not_owner
        render json: { errors: [ "Only the person who saved this memory can change or forget it." ] }, status: :forbidden
      end
    end
  end
end
