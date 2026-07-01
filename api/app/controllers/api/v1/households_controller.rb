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
        render json: budget_presenter.budget
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

      def budget_presenter
        return presenter if params[:year].blank?

        year = params[:year].to_i.clamp(2000, 2100)
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: year).plan_data
        HouseholdFinance::DataPresenter.new(current_household, user: current_user, annual_plan: annual_plan)
      end
    end
  end
end
