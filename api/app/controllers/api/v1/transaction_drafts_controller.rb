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

        append_chat_status_message(confirmed_message(result.draft))

        render json: {
          transaction_draft: serialize_draft(result.draft),
          transaction: serialize_transaction(result.transaction),
          workspace: workspace_payload_for(result.transaction.budget_period.budget_year.year)
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

        append_chat_status_message(ignored_message(@draft))

        render json: {
          transaction_draft: serialize_draft(@draft),
          workspace: workspace_payload_for(@draft.occurred_on.year)
        }
      end

      private

      def set_draft
        @draft = current_household.transaction_drafts.find(params[:id])
      end

      def confirm_params
        params.fetch(:transaction_draft, ActionController::Parameters.new).permit(:occurred_on, :merchant, :amount, :budget_category_id)
      end

      def append_chat_status_message(content)
        current_chat_session.chat_messages.create!(role: "assistant", content: content)
      rescue StandardError => e
        Rails.logger.warn("Transaction draft status message was not saved draft_id=#{@draft&.id}: #{e.class}: #{e.message}")
        false
      end

      def current_chat_session
        current_household.chat_sessions.find_by(user: current_user) ||
          current_household.chat_sessions.create!(user: current_user, title: "Ask Mia")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        current_household.chat_sessions.find_by!(user: current_user)
      end

      def workspace_payload_for(year)
        response_year = HouseholdFinance::AnnualBudgetManager.supported_year?(year) ? year : Date.current.year
        annual_plan = HouseholdFinance::AnnualBudgetManager.new(current_household, year: response_year).plan_data
        HouseholdFinance::DataPresenter.new(current_household.reload, user: current_user, annual_plan: annual_plan).app_data
      end

      def confirmed_message(draft)
        category = draft.budget_category&.name || "Uncategorized"
        "Confirmed #{draft.merchant} for #{money(draft.total_amount_cents)} in #{category}. I updated month-to-date actuals."
      end

      def ignored_message(draft)
        "Ignored #{draft.merchant} for #{money(draft.total_amount_cents)}. Month-to-date actuals did not change."
      end

      def money(cents)
        ActionController::Base.helpers.number_to_currency(
          HouseholdFinance::Money.dollars(cents),
          precision: cents.to_i % 100 == 0 ? 0 : 2
        )
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
