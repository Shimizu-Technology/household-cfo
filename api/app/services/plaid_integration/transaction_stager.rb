module PlaidIntegration
  class TransactionStager
    Result = Data.define(:drafts, :errors)

    def initialize(household:, user:, transaction_ids:)
      @household = household
      @user = user
      @transaction_ids = Array(transaction_ids).map(&:to_i).uniq
    end

    def call
      raise Error, "Select at least one posted expense" if transaction_ids.empty?

      drafts = ApplicationRecord.transaction do
        transactions = household.plaid_transactions.where(id: transaction_ids).includes(:plaid_account).lock.to_a
        raise Error, "One or more bank transactions were not found" unless transactions.length == transaction_ids.length
        raise Error, "Only unreviewed, posted expenses can be drafted" unless transactions.all?(&:stageable?)

        transactions.map { |transaction| stage!(transaction) }
      end
      Result.new(drafts: drafts, errors: [])
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :household, :user, :transaction_ids

    def stage!(transaction)
      merchant = (transaction.merchant_name.presence || transaction.name).first(120)
      category = HouseholdFinance::TransactionCategorySuggester.new(household).call(
        merchant: merchant,
        category_name: transaction.detailed_category,
        text: [ transaction.primary_category, transaction.detailed_category ].compact.join(" ")
      )
      HouseholdFinance::AnnualBudgetManager.new(household, year: transaction.occurred_on.year).ensure_plan!
      draft = household.transaction_drafts.create!(
        occurred_on: transaction.occurred_on,
        merchant: merchant,
        total_amount_cents: transaction.amount_cents,
        budget_category: category,
        source_type: "plaid",
        status: "pending",
        confidence: BigDecimal("0.80"),
        raw_input: "Bank-connected transaction for participant review",
        draft_payload: { parser: "plaid_transactions_sync_v1" }
      )
      draft.transaction_draft_splits.create!(
        budget_category: category,
        amount_cents: transaction.amount_cents,
        category_name: category&.name,
        stack_key: category&.stack_key,
        confidence: BigDecimal("0.80"),
        metadata: { source: "plaid" }
      )
      HouseholdFinance::TransactionDraftMatcher.new(draft).call
      transaction.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: transaction.source_fingerprint)
      household.household_audit_events.create!(user: user, actor_type: "user", event_type: "plaid_transaction.drafted", auditable_type: "TransactionDraft", auditable_id: draft.id, occurred_at: Time.current, metadata: { plaid_transaction_record_id: transaction.id })
      draft
    end
  end
end
