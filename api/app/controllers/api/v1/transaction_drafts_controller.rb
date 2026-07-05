module Api
  module V1
    class TransactionDraftsController < BaseController
      before_action :authenticate_user!
      before_action :set_draft, only: %i[update confirm ignore match reopen]

      def update
        result = HouseholdFinance::TransactionDraftUpdater.new(@draft, update_params).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        render json: {
          transaction_draft: serialize_draft(result.draft),
          workspace: workspace_payload_for(result.draft.occurred_on.year)
        }
      end

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
        ApplicationRecord.transaction do
          @draft.with_lock do
            raise ArgumentError, "Transaction draft is not pending" unless @draft.pending?

            @draft.update!(status: "ignored")
          end
          HouseholdFinance::DocumentImportStatusReconciler.new(@draft.financial_document_import).call if @draft.financial_document_import
        end
        append_chat_status_message(ignored_message(@draft))

        render json: {
          transaction_draft: serialize_draft(@draft.reload),
          workspace: workspace_payload_for(@draft.occurred_on.year)
        }
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
      end

      def match
        result = HouseholdFinance::TransactionDraftMatchAccepter.new(@draft, match_id: params[:match_id]).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        append_chat_status_message(matched_message(result.draft, result.match))

        render json: {
          transaction_draft: serialize_draft(result.draft),
          workspace: workspace_payload_for(result.draft.occurred_on.year)
        }
      end

      def reopen
        result = HouseholdFinance::TransactionDraftReopener.new(@draft).call
        unless result.success?
          return render json: { errors: result.errors }, status: :unprocessable_entity
        end

        append_chat_status_message(reopened_message(result.draft))

        render json: {
          transaction_draft: serialize_draft(result.draft),
          workspace: workspace_payload_for(result.draft.occurred_on.year)
        }
      end

      private

      def set_draft
        @draft = current_household.transaction_drafts.find(params[:id])
      end

      def confirm_params
        permitted_draft_params.permit(:occurred_on, :merchant, :amount, :budget_category_id, splits: [ :id, :amount, :budget_category_id, :category_name, :stack_key, :notes, :confidence ])
      end

      def update_params
        permitted_draft_params.permit(:occurred_on, :merchant, :amount, :budget_category_id, splits: [ :id, :amount, :budget_category_id, :category_name, :stack_key, :notes, :confidence ])
      end

      def permitted_draft_params
        draft_params = params[:transaction_draft]
        draft_params = ActionController::Parameters.new unless draft_params.is_a?(ActionController::Parameters)
        draft_params
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

      def matched_message(draft, match)
        transaction = match.household_transaction
        "Matched #{draft.merchant} for #{money(draft.total_amount_cents)} to the existing #{transaction.merchant} transaction on #{transaction.occurred_on.to_fs(:long)}. Month-to-date actuals did not change."
      end

      def reopened_message(draft)
        "Reopened #{draft.merchant} for #{money(draft.total_amount_cents)} for review. Actuals were adjusted if this draft had created a confirmed transaction."
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
          amount_cents: draft.total_amount_cents,
          status: draft.status,
          source_type: draft.source_type,
          category_id: draft.budget_category_id,
          category_name: draft.budget_category&.name,
          financial_document_import_id: draft.financial_document_import_id,
          splits: ordered_draft_splits_for(draft).map { |split| serialize_split(split) },
          matches: ordered_draft_matches_for(draft).map { |match| serialize_match(match) },
          matched_transaction_id: draft.matched_transaction_id
        }
      end

      def ordered_draft_splits_for(draft)
        if draft.association(:transaction_draft_splits).loaded?
          draft.transaction_draft_splits.sort_by(&:id)
        else
          draft.transaction_draft_splits.ordered.includes(:budget_category)
        end
      end

      def ordered_draft_matches_for(draft)
        matches = if draft.association(:transaction_draft_matches).loaded?
          draft.transaction_draft_matches
        else
          draft.transaction_draft_matches.includes(household_transaction: { transaction_splits: :budget_category })
        end
        matches.sort_by { |match| [ -(match.confidence || 0).to_d, match.id || 0 ] }
      end

      def serialize_split(split)
        {
          id: split.id,
          budget_category_id: split.budget_category_id,
          category_name: split.budget_category&.name || split.category_name,
          stack_key: split.budget_category&.stack_key || split.stack_key,
          stack_label: split.budget_category&.stack_label || split.stack_key.to_s.humanize,
          amount: HouseholdFinance::Money.dollars(split.amount_cents),
          amount_cents: split.amount_cents,
          notes: split.notes,
          confidence: split.confidence
        }
      end

      def serialize_match(match)
        transaction = match.household_transaction
        {
          id: match.id,
          status: match.status,
          confidence: match.confidence,
          match_reason: match.match_reason,
          transaction: {
            id: transaction.id,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            amount: HouseholdFinance::Money.dollars(transaction.total_amount_cents),
            source_type: transaction.source_type,
            categories: transaction.transaction_splits.filter_map { |split| split.budget_category&.name }
          }
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
