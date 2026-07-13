module Api
  module V1
    module Plaid
      class TransactionsController < BaseController
        MAX_PAGE_SIZE = 100

        before_action :authenticate_user!

        def index
          scope = current_household.plaid_transactions.visible.includes(:plaid_account, :transaction_draft).recent_first
          scope = scope.where(plaid_account_id: params[:account_id]) if params[:account_id].present?
          scope = scope.where(review_status: params[:status]) if params[:status].to_s.in?(PlaidTransaction::REVIEW_STATUSES)
          limit = params.fetch(:limit, 50).to_i.clamp(1, MAX_PAGE_SIZE)
          page = params.fetch(:page, 1).to_i.clamp(1, 10_000)
          total = scope.count
          transactions = scope.offset((page - 1) * limit).limit(limit)
          render json: {
            transactions: transactions.map { |transaction| serialize_transaction(transaction) },
            pagination: { page: page, per_page: limit, total: total, has_more: page * limit < total }
          }
        end

        def stage
          result = PlaidIntegration::TransactionStager.new(household: current_household, user: current_user, transaction_ids: params[:transaction_ids]).call
          render json: { drafted_count: result.drafts.length, transaction_draft_ids: result.drafts.map(&:id) }
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        def ignore
          ids = Array(params[:transaction_ids]).map(&:to_i).uniq
          return render json: { errors: [ "Select at least one bank transaction" ] }, status: :unprocessable_entity if ids.empty?

          updated = current_household.plaid_transactions.visible.where(id: ids, pending: false, review_status: "unreviewed").update_all(review_status: "ignored", updated_at: Time.current)
          return render json: { errors: [ "One or more bank transactions could not be ignored" ] }, status: :unprocessable_entity unless updated == ids.length

          current_household.household_audit_events.create!(user: current_user, actor_type: "user", event_type: "plaid_transactions.ignored", occurred_at: Time.current, metadata: { transaction_record_ids: ids })
          render json: { ignored_count: updated }
        end

        private

        def serialize_transaction(transaction)
          {
            id: transaction.id,
            account_id: transaction.plaid_account_id,
            account_name: transaction.plaid_account.name,
            account_mask: transaction.plaid_account.mask,
            name: transaction.name,
            merchant_name: transaction.merchant_name,
            occurred_on: transaction.occurred_on,
            authorized_on: transaction.authorized_on,
            amount_cents: transaction.amount_cents,
            pending: transaction.pending,
            direction: transaction.amount_cents.positive? ? "outflow" : "inflow",
            primary_category: transaction.primary_category,
            detailed_category: transaction.detailed_category,
            review_status: transaction.review_status,
            stageable: transaction.stageable?,
            transaction_draft_id: transaction.transaction_draft_id,
            source_changed_after_draft: transaction.transaction_draft_id.present? && transaction.drafted_source_fingerprint.present? && transaction.source_fingerprint != transaction.drafted_source_fingerprint
          }
        end
      end
    end
  end
end
