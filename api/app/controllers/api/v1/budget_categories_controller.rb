module Api
  module V1
    class BudgetCategoriesController < BaseController
      before_action :authenticate_user!

      def create
        category = budget_manager.create_category!(
          name: category_params[:name],
          stack_key: category_params[:stack_key],
          monthly_amount: category_params[:monthly_amount]
        )

        render_category_response(category, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      end

      def update
        category = budget_manager.update_category!(
          scoped_category,
          name: category_params[:name],
          stack_key: category_params[:stack_key]
        )

        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def destroy
        category = budget_manager.archive_category!(scoped_category)

        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def restore
        category = budget_manager.restore_category!(scoped_category)

        render_category_response(category)
      rescue ActiveRecord::RecordNotFound
        render json: { errors: [ "Budget category not found" ] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def budget_manager
        @budget_manager ||= HouseholdFinance::AnnualBudgetManager.new(current_household, year: budget_year_param)
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
          budget: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: budget_manager.plan_data).budget
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
