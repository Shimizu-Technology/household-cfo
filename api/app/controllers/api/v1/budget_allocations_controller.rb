module Api
  module V1
    class BudgetAllocationsController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def update
        allocation = current_household_allocation_scope.find(params[:id])
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household, year: allocation.budget_period.budget_year.year)
        result = HouseholdFinance::Operations::Runner.new(current_household, user: current_user).run(
          operation_key: "budget.allocation.set",
          input: {
            allocation_id: allocation.id,
            category_id: allocation.budget_category_id,
            year: allocation.budget_period.budget_year.year,
            planned_amount: allocation_params[:planned_amount]
          },
          idempotency_key: request_idempotency_key
        )
        allocation = result.subject || allocation.reload
        annual_plan = manager.plan_data

        render json: {
          allocation: serialize_allocation(allocation.reload),
          budget: current_data_presenter(household: current_household.reload, annual_plan: annual_plan).budget
        }
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget allocation not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
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
