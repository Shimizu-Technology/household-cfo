module Api
  module V1
    class WorkspacesController < BaseController
      before_action :authenticate_user!

      def show
        render_current_workspace
      end

      def setup
        workspace_data = nil
        current_household.transaction do
          HouseholdFinance::SetupUpdater.new(current_household, setup_params).call
          workspace_data = current_workspace_data
          record_setup_save!(workspace_data.dig(:workspace, :setup_complete))
        end
        render json: workspace_data
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def record_setup_save!(setup_complete)
        current_household.household_audit_events.create!(
          user: current_user,
          actor_type: "user",
          event_type: "workspace.setup_saved",
          metadata: { setup_complete: setup_complete },
          occurred_at: Time.current
        )
      end

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
