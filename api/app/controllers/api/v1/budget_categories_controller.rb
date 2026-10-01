module Api
  module V1
    class BudgetCategoriesController < BaseController
      before_action :authenticate_user!
      before_action :require_writable_household!

      def create
        result = operation_runner.run(
          operation_key: "budget.category.create",
          input: category_params.to_h.merge(year: budget_year_param),
          idempotency_key: request_idempotency_key
        )
        category = result.subject || current_household.budget_categories.find(result.execution.subject_id)
        render_category_response(category, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def update
        category = scoped_category
        result = operation_runner.run(
          operation_key: "budget.category.update",
          input: category_params.to_h.merge(category_id: category.id, year: budget_year_param),
          idempotency_key: request_idempotency_key
        )
        category = result.subject || category.reload
        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def destroy
        category = scoped_category
        result = operation_runner.run(
          operation_key: "budget.category.archive",
          input: { category_id: category.id, year: budget_year_param },
          idempotency_key: request_idempotency_key
        )
        category = result.subject || category.reload

        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      def restore
        category = scoped_category
        result = operation_runner.run(
          operation_key: "budget.category.restore",
          input: { category_id: category.id, year: budget_year_param },
          idempotency_key: request_idempotency_key
        )
        category = result.subject || category.reload

        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render_operation_error(e)
      end

      private

      def budget_manager
        @budget_manager ||= HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
      end

      def operation_runner
        @operation_runner ||= HouseholdFinance::Operations::Runner.new(current_household, user: current_user)
      end

      def budget_year_param
        return Date.current.year if params[:year].blank?

        params[:year].to_i.clamp(2000, 2100)
      end

      def scoped_category
        current_household.budget_categories.find(params[:id])
      end

      def category_params
        params.require(:category).permit(:name, :stack_key, :monthly_amount)
      end

      def render_category_response(category, status: :ok)
        render json: {
          category: serialize_category(category),
          budget: current_data_presenter(household: current_household.reload, annual_plan: budget_manager.plan_data).budget
        }, status: status
      end

      def serialize_category(category)
        {
          id: category.id,
          name: category.name,
          stack_key: category.stack_key,
          stack_label: category.stack_label,
          active: category.active
        }
      end
    end
  end
end
