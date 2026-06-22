module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        def index
          render json: { users: User.order(:email).map(&:as_api_json) }
        end

        def create
          role = requested_role
          return render json: { errors: [ "Role is not valid" ] }, status: :unprocessable_entity unless User::ROLES.include?(role)
          return render_forbidden("Role assignment not permitted") unless role_assignable_by_current_user?(role)

          user = User.create!(
            email: user_params[:email],
            first_name: user_params[:first_name],
            last_name: user_params[:last_name],
            role: role,
            clerk_id: pending_clerk_id,
            invitation_status: "pending",
            invited_at: Time.current
          )
          render json: { user: user.as_api_json }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def user_params
          params.require(:user).permit(:email, :first_name, :last_name)
        end

        def requested_role
          params.dig(:user, :role).presence || "participant"
        end

        def role_assignable_by_current_user?(role)
          return true if current_user.admin?

          current_user.coach? && role == "participant"
        end

        def pending_clerk_id
          "pending_#{SecureRandom.hex(12)}"
        end
      end
    end
  end
end
