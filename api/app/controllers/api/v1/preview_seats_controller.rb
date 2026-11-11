module Api
  module V1
    # Coaches and admins take a preview seat in a group to use the app as one of
    # its members. The seat is never part of the program (see PreviewSeats).
    class PreviewSeatsController < BaseController
      before_action :authenticate_user!
      before_action :require_staff!
      before_action { response.set_header("Cache-Control", "private, no-store") }
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "That group isn't available to preview." ], code: "preview_group_unavailable" }, status: :not_found
      end

      def create
        PreviewSeats.join!(user: current_user, cohort_id: params.require(:cohort_id))
        render json: { preview_groups: PreviewSeats.groups_for(current_user) }, status: :created
      end

      def destroy
        message = PreviewSeats.leave!(user: current_user, cohort_id: params[:id])
        render json: { message: message, preview_groups: PreviewSeats.groups_for(current_user) }
      end
    end
  end
end
