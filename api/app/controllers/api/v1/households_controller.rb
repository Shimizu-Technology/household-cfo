module Api
  module V1
    class HouseholdsController < BaseController
      before_action :authenticate_user!
      before_action -> { require_experience_module!("optionality") }, only: :optionality
      before_action -> { require_experience_module!("cfo_filter") }, only: :cfo_filter

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
        @presenter ||= current_data_presenter
      end

      def budget_presenter
        return presenter if params[:year].blank?

        year = params[:year].to_i.clamp(2000, 2100)
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: year).plan_data
        current_data_presenter(annual_plan: annual_plan)
      end
    end
  end
end
