module Api
  module V1
    class TransactionDraftsController < BaseController
      before_action :authenticate_user!
      before_action :set_draft, only: %i[confirm ignore]

      def confirm
        result = HouseholdFinance::TransactionDraftConfirmer.new(@draft, confirm_params).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        render json: {
          transaction_draft: serialize_draft(result.draft),
          transaction: serialize_transaction(result.transaction),
          workspace: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user).app_data
        }
      end

      def ignore
        ignored = false
        @draft.with_lock do
          if @draft.pending?
            @draft.update!(status: "ignored")
            ignored = true
          end
        end

        unless ignored
          return render json: { errors: [ "Transaction draft is not pending" ] }, status: :unprocessable_entity
        end

        render json: {
          transaction_draft: serialize_draft(@draft),
          workspace: HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user).app_data
        }
      end

      private

      def set_draft
        @draft = current_household.transaction_drafts.find(params[:id])
      end

      def confirm_params
        params.fetch(:transaction_draft, {}).permit(:occurred_on, :merchant, :amount, :budget_category_id)
      end

      def serialize_draft(draft)
        {
          id: draft.id,
          occurred_on: draft.occurred_on&.iso8601,
          merchant: draft.merchant,
          amount: HouseholdFinance::Money.dollars(draft.total_amount_cents),
          status: draft.status,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name
        }
      end

      def serialize_transaction(transaction)
        {
          id: transaction.id,
          occurred_on: transaction.occurred_on.iso8601,
          merchant: transaction.merchant,
          amount: HouseholdFinance::Money.dollars(transaction.total_amount_cents)
        }
      end
    end
  end
end
