module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable

      private

      def current_household
        @current_household ||= HouseholdFinance::WorkspaceResolver.new(current_user).household
      end

      def require_writable_household!
        membership = current_household.household_memberships.find_by(user_id: current_user.id)
        return if membership&.role.in?(%w[owner partner])

        render json: { errors: [ "This household is read-only for your account." ] }, status: :forbidden
      end

      def render_current_workspace
        render json: current_workspace_data
      end

      def current_workspace_data
        HouseholdFinance::DataPresenter.new(current_household, user: current_user).app_data
      end
    end
  end
end
