module Api
  module V1
    class BudgetCategoriesController < BaseController
      before_action :authenticate_user!

      def create
        manager = HouseholdFinance::AnnualBudgetManager.new(current_household)
        category = manager.create_category!(
          name: category_params[:name],
          stack_key: category_params[:stack_key],
          monthly_amount: category_params[:monthly_amount]
        )

        render json: {
          category: serialize_category(category),
          budget: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user).budget
        }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def category_params
        params.require(:category).permit(:name, :stack_key, :monthly_amount)
      end

      def serialize_category(category)
        {
          id: category.id,
          name: category.name,
          stack_key: category.stack_key,
          stack_label: category.stack_label
        }
      end
    end
  end
end
