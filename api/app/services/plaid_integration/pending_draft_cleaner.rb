module PlaidIntegration
  class PendingDraftCleaner
    def initialize(household:, transactions:)
      @household = household
      @transactions = transactions
    end

    def call
      pending_source_drafts.destroy_all
    end

    private

    attr_reader :household, :transactions

    def pending_source_drafts
      household.transaction_drafts.pending
        .where(source_type: "plaid")
        .where(id: transactions.where.not(transaction_draft_id: nil).select(:transaction_draft_id))
    end
  end
end
