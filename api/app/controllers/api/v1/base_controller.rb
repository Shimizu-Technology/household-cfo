module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable

      private

      def current_household
        @current_household ||= HouseholdFinance::WorkspaceResolver.new(current_user).household
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
