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
        render json: params[:scenario] == "1" ? presenter.optionality_scenario(scenario_inputs(%w[savings_cents monthly_costs_cents replacement_income_cents monthly_draw_cents])) : presenter.optionality
      end

      def cfo_filter
        render json: params[:scenario] == "1" ? presenter.cfo_filter_scenario(**scenario_inputs(%w[spend_cents windfall_cents lift_cents])) : presenter.cfo_filter
      end

      private

      def scenario_inputs(keys)
        keys.each_with_object({}) do |key, result|
          next unless params.key?(key)

          value = params[key].to_s
          raise ActionController::BadRequest, "Enter a nonnegative amount in cents" unless value.match?(/\A\d{1,9}\z/) && value.to_i <= HouseholdFinance::Money::MAX_AMOUNT_CENTS

          result[key.to_sym] = value.to_i
        end
      end

      def presenter
        @presenter ||= current_data_presenter(initialize_missing_plan: params[:scenario] != "1")
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
