module Api
  module V1
    class MiaMemorySettingsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def update
        membership = current_household.household_memberships.find_by!(user_id: current_user.id)
        paused = ActiveModel::Type::Boolean.new.cast(params.require(:personalization).require(:paused))
        if membership.mia_personalization_paused? != paused
          membership.update!(mia_personalization_paused: paused, mia_personalization_paused_at: paused ? Time.current : nil)
          current_household.household_audit_events.create!(
            user: current_user, actor_type: "user", event_type: paused ? "mia_memory.paused" : "mia_memory.resumed",
            occurred_at: Time.current, metadata: {}
          )
        end
        render json: { personalization: { paused: paused, paused_at: membership.mia_personalization_paused_at&.iso8601 } }
      end
    end
  end
end
