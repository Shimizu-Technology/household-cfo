module Api
  module V1
    class BudgetAllocationsController < BaseController
      before_action :authenticate_user!

      def update
        allocation = current_household_allocation_scope.find(params[:id])
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: allocation.budget_period.budget_year.year)
        manager.update_allocation!(allocation, allocation_params[:planned_amount])
        annual_plan = manager.plan_data

        render json: {
          allocation: serialize_allocation(allocation.reload),
          budget: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).budget
        }
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget allocation not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def current_household_allocation_scope
        BudgetAllocation
          .includes(:budget_category, budget_period: :budget_year)
          .joins(:budget_category, budget_period: :budget_year)
          .where(budget_categories: { household_id: current_household.id }, budget_years: { household_id: current_household.id })
      end

      def allocation_params
        params.require(:allocation).permit(:planned_amount)
      end

      def serialize_allocation(allocation)
        {
          id: allocation.id,
          planned: HouseholdFinance::Money.dollars(allocation.planned_amount_cents)
        }
      end
    end
  end
end
