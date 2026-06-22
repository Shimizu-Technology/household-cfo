module Api
  module V1
    class HouseholdsController < BaseController
      before_action :authenticate_user!

      def profile
        render json: presenter.profile
      end

      def dashboard
        render json: presenter.dashboard
      end

      def budget
        render json: presenter.budget
      end

      def wealth
        render json: presenter.wealth
      end

      def optionality
        render json: presenter.optionality
      end

      def cfo_filter
        render json: presenter.cfo_filter
      end

      private

      def presenter
        @presenter ||= HouseholdFinance::DataPresenter.new(current_household, user: current_user)
      end
    end
  end
end
