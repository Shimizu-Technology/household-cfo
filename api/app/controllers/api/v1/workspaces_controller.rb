module Api
  module V1
    class WorkspacesController < BaseController
      before_action :authenticate_user!

      def show
        render_current_workspace
      end

      def setup
        HouseholdFinance::SetupUpdater.new(current_household, setup_params).call
        render_current_workspace
      end

      private

      def setup_params
        params.require(:workspace).permit(
          :household_name,
          :primary_goal,
          :primary_income,
          :business_income,
          :fixed_expenses,
          :flexible_spend,
          :expected_sinking_fund,
          :unexpected_sinking_fund,
          :emergency_fund,
          :other_assets,
          :credit_card_debt,
          :debt_payment,
          :target_runway_months
        )
      end
    end
  end
end
