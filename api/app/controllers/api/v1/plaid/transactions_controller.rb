module Api
  module V1
    module Plaid
      class TransactionsController < BaseController
        MAX_PAGE_SIZE = 100
        ACTIVITY_VIEWS = %w[all needs_review confirmed excluded pending inflow].freeze

        before_action :authenticate_user!

        def index
          account_id = params[:account_id].presence
          scope = scope_for_account(activity_scope, account_id)
          scope = apply_search(scope, params[:query])
          scope = apply_activity_view(scope, params[:view].to_s.presence_in(ACTIVITY_VIEWS) || "all")
          limit = params.fetch(:limit, 50).to_i.clamp(1, MAX_PAGE_SIZE)
          page = params.fetch(:page, 1).to_i.clamp(1, 10_000)
          review_year = params.fetch(:review_year, Date.current.year).to_i.clamp(2000, 2100)
          total = scope.count
          transactions = scope.includes(:plaid_account, transaction_draft: [ :budget_category, { transaction_draft_splits: :budget_category }, { confirmed_transaction: :budget_categories } ]).recent_first.offset((page - 1) * limit).limit(limit)
          render json: {
            transactions: transactions.map { |transaction| serialize_transaction(transaction) },
            pagination: { page: page, per_page: limit, total: total, has_more: page * limit < total },
            summary: activity_summary(account_id: account_id, review_year: review_year)
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

          ignored_count = ApplicationRecord.transaction do
            transactions = current_household.plaid_transactions.visible.where(id: ids).lock.to_a
            unless transactions.length == ids.length && transactions.all? { |transaction| !transaction.pending? && transaction.review_status == "unreviewed" }
              raise PlaidIntegration::Error, "One or more bank transactions could not be ignored"
            end

            updated = PlaidTransaction.where(id: transactions.map(&:id)).update_all(review_status: "ignored", updated_at: Time.current)
            current_household.household_audit_events.create!(user: current_user, actor_type: "user", event_type: "plaid_transactions.ignored", occurred_at: Time.current, metadata: { transaction_record_ids: ids })
            updated
          end
          render json: { ignored_count: ignored_count }
        rescue PlaidIntegration::Error => e
          render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        private

        def activity_scope
          current_household.plaid_transactions
            .where("plaid_transactions.removed_at IS NULL OR plaid_transactions.transaction_draft_id IS NOT NULL")
        end

        def apply_activity_view(scope, view)
          joined = scope.left_joins(:transaction_draft)
          case view
          when "needs_review"
            joined.where(pending: false).where("amount_cents > 0").where(<<~SQL.squish)
              plaid_transactions.removed_at IS NOT NULL OR
              (plaid_transactions.drafted_source_fingerprint IS NOT NULL AND plaid_transactions.source_fingerprint <> plaid_transactions.drafted_source_fingerprint) OR
              plaid_transactions.review_status = 'unreviewed' OR
              transaction_drafts.status = 'pending'
            SQL
          when "confirmed"
            joined.where(removed_at: nil, transaction_drafts: { status: %w[confirmed corrected matched] })
          when "excluded"
            joined.where("plaid_transactions.review_status = 'ignored' OR transaction_drafts.status = 'ignored'")
          when "pending"
            scope.where(pending: true, removed_at: nil)
          when "inflow"
            scope.where("amount_cents < 0").where(removed_at: nil)
          else
            scope
          end
        end

        def apply_search(scope, query)
          normalized = query.to_s.strip
          return scope if normalized.blank?

          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized)}%"
          scope.where("plaid_transactions.name ILIKE :pattern OR plaid_transactions.merchant_name ILIKE :pattern", pattern: pattern)
        end

        def scope_for_account(scope, account_id)
          return scope if account_id.blank?

          scope.where(plaid_transactions: { plaid_account_id: account_id })
        end

        def activity_summary(account_id: nil, review_year: Date.current.year)
          current = scope_for_account(current_household.plaid_transactions.visible, account_id)
          account_activity = scope_for_account(activity_scope, account_id)
          posted = current.where(pending: false).where("amount_cents > 0")
          pending = current.where(pending: true).where("amount_cents > 0")
          inflow = current.where("amount_cents < 0")
          needs_review = apply_activity_view(account_activity, "needs_review")
          year_range = Date.new(review_year, 1, 1)..Date.new(review_year, 12, 31)
          year_needs_review = needs_review.where(occurred_on: year_range)
          confirmed_sources = apply_activity_view(account_activity, "confirmed")
          excluded = apply_activity_view(account_activity, "excluded")
          confirmed_actuals = confirmed_actuals_for(confirmed_sources, account_id: account_id)

          {
            all_count: account_activity.count,
            posted_outflow_count: posted.count,
            posted_outflow_cents: posted.sum(:amount_cents),
            pending_count: pending.count,
            pending_cents: pending.sum(:amount_cents),
            inflow_count: inflow.count,
            inflow_cents: inflow.sum(:amount_cents).abs,
            needs_review_count: needs_review.count,
            needs_review_cents: needs_review.where("plaid_transactions.removed_at IS NULL").sum(:amount_cents),
            review_year: review_year,
            review_year_needs_review_count: year_needs_review.count,
            review_year_needs_review_cents: year_needs_review.where("plaid_transactions.removed_at IS NULL").sum(:amount_cents),
            other_years_needs_review_count: needs_review.where.not(occurred_on: year_range).count,
            confirmed_count: confirmed_sources.count,
            confirmed_actual_count: confirmed_actuals.count,
            confirmed_cents: confirmed_actuals.sum(:total_amount_cents),
            excluded_count: excluded.count
          }
        end

        def confirmed_actuals_for(confirmed_sources, account_id: nil)
          actuals = current_household.household_transactions.where(source_type: "plaid", status: %w[confirmed reconciled])
          return actuals if account_id.blank?

          linked_drafts = TransactionDraft.where(id: confirmed_sources.select("plaid_transactions.transaction_draft_id"))
          linked_by_confirmation = actuals.where(id: linked_drafts.select(:confirmed_transaction_id))
          linked_by_match = actuals.where(id: linked_drafts.select(:matched_transaction_id))
          linked_by_confirmation.or(linked_by_match)
        end

        def serialize_transaction(transaction)
          draft = transaction.transaction_draft
          confirmed_transaction = draft&.confirmed_transaction
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
            transaction_draft_status: draft&.status,
            confirmed_transaction_id: confirmed_transaction&.id,
            confirmed_amount_cents: confirmed_transaction&.total_amount_cents,
            category_names: confirmed_transaction&.budget_categories&.map(&:name)&.uniq.presence || draft_category_names(draft),
            trust_state: trust_state(transaction, draft),
            removed: transaction.removed_at.present?,
            source_changed_after_draft: source_changed?(transaction)
          }
        end

        def draft_category_names(draft)
          return [] unless draft

          names = draft.transaction_draft_splits.filter_map { |split| split.category_name.presence || split.budget_category&.name }
          names.presence || [ draft.budget_category&.name ].compact
        end

        def trust_state(transaction, draft)
          return "source_changed" if transaction.removed_at.present? || source_changed?(transaction)
          return "bank_pending" if transaction.pending?
          return "money_in" if transaction.amount_cents.negative?
          return "excluded" if transaction.review_status == "ignored" || draft&.status == "ignored"
          return "needs_review" if transaction.review_status == "unreviewed" || draft&.status == "pending"
          return "confirmed" if draft&.status.in?(%w[confirmed corrected matched])

          "bank_observed"
        end

        def source_changed?(transaction)
          transaction.transaction_draft_id.present? && transaction.drafted_source_fingerprint.present? && transaction.source_fingerprint != transaction.drafted_source_fingerprint
        end
      end
    end
  end
end
