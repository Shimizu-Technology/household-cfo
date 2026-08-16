module PlaidIntegration
  class AutoConfirmer
    MIN_CONFIRMATIONS = 3
    MIN_CONFIDENCE = BigDecimal("0.89")
    MAX_AMOUNT_GROWTH = BigDecimal("1.25")

    def initialize(plaid_item, drafts: nil)
      @plaid_item = plaid_item
      @drafts = drafts
    end

    def call
      candidates.filter_map { |draft| confirm_if_trusted(draft) }
    end

    private

    attr_reader :plaid_item, :drafts

    def candidates
      scope = plaid_item.household.transaction_drafts.pending.where(source_type: "plaid")
      scope = scope.where(id: drafts.map(&:id)) if drafts
      scope.includes(:budget_category, :transaction_draft_matches)
    end

    def confirm_if_trusted(draft)
      rule = trusted_rule(draft)
      return unless rule
      return unless draft.budget_category_id == rule.budget_category_id
      return if draft.transaction_draft_matches.where(status: "proposed").exists?
      return unless amount_is_familiar?(draft)

      result = HouseholdFinance::TransactionDraftConfirmer.new(draft).call
      return unless result.success?

      plaid_item.household.household_audit_events.create!(
        user: plaid_item.connected_by_user,
        actor_type: "system",
        event_type: "plaid_transaction.auto_confirmed",
        auditable_type: "HouseholdTransaction",
        auditable_id: result.transaction.id,
        occurred_at: Time.current,
        metadata: { transaction_draft_id: draft.id, merchant_rule_id: rule.id }
      )
      result.transaction
    end

    def trusted_rule(draft)
      pattern = MerchantCategoryRule.normalized_pattern(draft.merchant)
      return if pattern.blank?

      plaid_item.household.merchant_category_rules.active
        .joins(:budget_category)
        .where(merchant_pattern: pattern, source: "user_confirmed")
        .where.not("LOWER(budget_categories.name) IN (?)", [ "uncategorized", "needs category" ])
        .where("times_confirmed >= ? AND confidence >= ?", MIN_CONFIRMATIONS, MIN_CONFIDENCE)
        .best_first
        .first
    end

    def amount_is_familiar?(draft)
      pattern = MerchantCategoryRule.normalized_pattern(draft.merchant)
      matching_amounts = []
      plaid_item.household.household_transactions
        .where(source_type: "plaid", status: %w[confirmed reconciled])
        .select(:id, :merchant, :total_amount_cents)
        .find_each(batch_size: 500) do |transaction|
          matching_amounts << transaction.total_amount_cents if MerchantCategoryRule.normalized_pattern(transaction.merchant) == pattern
        end
      return false if matching_amounts.length < MIN_CONFIRMATIONS

      draft.total_amount_cents <= (matching_amounts.max * MAX_AMOUNT_GROWTH).round
    end
  end
end
