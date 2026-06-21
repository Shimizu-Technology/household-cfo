module Api
  module V1
    class AuthController < BaseController
      before_action :authenticate_user!

      def me
        render json: { user: current_user.as_api_json }
      end
    end
  end
end
