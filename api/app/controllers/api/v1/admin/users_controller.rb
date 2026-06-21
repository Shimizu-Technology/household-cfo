module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :require_staff!

        def index
          render json: { users: User.order(:email).map(&:as_api_json) }
        end

        def create
          user = User.create!(user_params.merge(clerk_id: pending_clerk_id, invitation_status: "pending", invited_at: Time.current))
          render json: { user: user.as_api_json }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def user_params
          params.require(:user).permit(:email, :first_name, :last_name, :role)
        end

        def pending_clerk_id
          "pending_#{SecureRandom.hex(12)}"
        end
      end
    end
  end
end
