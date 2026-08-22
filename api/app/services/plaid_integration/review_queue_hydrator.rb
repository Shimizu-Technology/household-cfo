module PlaidIntegration
  class ReviewQueueHydrator
    BATCH_SIZE = 100

    def initialize(plaid_item)
      @plaid_item = plaid_item
    end

    def call
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
