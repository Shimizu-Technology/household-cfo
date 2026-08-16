module PlaidIntegration
  class ReviewQueueHydrator
    BATCH_SIZE = 100

    def initialize(plaid_item)
      @plaid_item = plaid_item
    end

    def call
      staged = []
      plaid_item.plaid_transactions.stageable.in_batches(of: BATCH_SIZE) do |batch|
        result = TransactionStager.new(
          household: plaid_item.household,
          user: plaid_item.connected_by_user,
          transaction_ids: batch.pluck(:id),
          actor_type: "system"
        ).call
        staged.concat(result.drafts)
      end

      AutoConfirmer.new(plaid_item, drafts: staged).call if plaid_item.auto_confirm_trusted_merchants?
      staged
    end

    private

    attr_reader :plaid_item
  end
end
