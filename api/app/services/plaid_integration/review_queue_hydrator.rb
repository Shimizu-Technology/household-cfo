module PlaidIntegration
  class ReviewQueueHydrator
    BATCH_SIZE = 100

    def initialize(plaid_item)
      @plaid_item = plaid_item
    end

    def call
      return [] unless plaid_item.current_financial_picture?

      release_non_spending_drafts
      staged = []
      plaid_item.plaid_transactions.stageable.in_batches(of: BATCH_SIZE) do |batch|
        transaction_ids = batch.pluck(:id)
        begin
          result = TransactionStager.new(
            household: plaid_item.household,
            user: plaid_item.connected_by_user,
            transaction_ids: transaction_ids,
            actor_type: "system"
          ).call
          staged.concat(result.drafts)
        rescue StandardError => error
          report_handled_error(error, operation: "plaid_review_queue_hydration", transaction_count: transaction_ids.length)
        end
      end

      auto_confirm(staged) if plaid_item.auto_confirm_trusted_merchants?
      staged
    end

    private

    attr_reader :plaid_item

    # Earlier syncs queued transfers and card/loan payments as spending drafts.
    # Return still-untouched, undecided ones to bank activity, where they are
    # shown as not counted as spending. Decided or participant-edited drafts are
    # left alone, and one failing row never blocks the rest.
    def release_non_spending_drafts
      drafts = plaid_item.household.transaction_drafts.pending.where(source_type: "plaid")
      plaid_item.plaid_transactions.current_picture.visible.not_counted_as_spending
        .where(review_status: "drafted", transaction_draft_id: drafts.select(:id))
        .find_each do |transaction|
          release_draft!(transaction)
        rescue ActiveRecord::ActiveRecordError => error
          report_handled_error(error, operation: "plaid_non_spending_release", transaction_count: 1)
        end
    end

    def untouched_draft?(transaction, draft)
      splits = draft.transaction_draft_splits.to_a
      draft.budget_category_id.nil? && draft.matched_transaction_id.nil? && draft.confirmed_transaction_id.nil? &&
        draft.total_amount_cents == transaction.amount_cents && draft.occurred_on == transaction.occurred_on &&
        draft.merchant == (transaction.merchant_name.presence || transaction.name).first(120) &&
        splits.length == 1 && splits.first.budget_category_id.nil? && splits.first.notes.blank? && splits.first.amount_cents == transaction.amount_cents
    end

    def release_draft!(transaction)
      ApplicationRecord.transaction do
        transaction.lock!
        draft = transaction.transaction_draft&.lock!
        next unless draft&.pending? && draft.source_type == "plaid" && !transaction.counts_as_spending?
        next unless untouched_draft?(transaction, draft)

        prior = { draft: draft.attributes.slice("merchant", "occurred_on", "total_amount_cents", "budget_category_id", "draft_payload", "raw_input"), splits: draft.transaction_draft_splits.map { |split| split.attributes.slice("amount_cents", "budget_category_id", "category_name", "notes", "metadata") } }
        transaction.update!(transaction_draft: nil, review_status: "unreviewed", drafted_source_fingerprint: nil)
        draft.destroy!
        plaid_item.household.household_audit_events.create!(
          user: plaid_item.connected_by_user, actor_type: "system", event_type: "plaid_transaction.not_counted_as_spending",
          occurred_at: Time.current, metadata: { plaid_transaction_record_id: transaction.id, movement_type: transaction.movement_type, released_transaction_draft_id: draft.id, prior_draft: prior }
        )
      end
    end

    def auto_confirm(staged)
      AutoConfirmer.new(plaid_item, drafts: staged).call
    rescue StandardError => error
      report_handled_error(error, operation: "plaid_auto_confirmation", transaction_count: staged.length)
    end

    def report_handled_error(error, operation:, transaction_count:)
      Rails.error.report(
        error,
        handled: true,
        context: {
          plaid_item_record_id: plaid_item.id,
          transaction_count: transaction_count,
          operation: operation
        }
      )
    end
  end
end
