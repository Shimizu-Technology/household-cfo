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
      stats = confirmed_amount_stats.fetch(pattern, { count: 0, maximum_cents: 0 })
      return false if stats[:count] < MIN_CONFIRMATIONS

      draft.total_amount_cents <= (stats[:maximum_cents] * MAX_AMOUNT_GROWTH).round
    end

    def confirmed_amount_stats
      @confirmed_amount_stats ||= begin
        stats = Hash.new { |hash, pattern| hash[pattern] = { count: 0, maximum_cents: 0 } }

        plaid_item.household.household_transactions
          .where(source_type: "plaid", status: %w[confirmed reconciled])
          .select(:id, :merchant, :total_amount_cents)
          .find_each(batch_size: 500) do |transaction|
            pattern = MerchantCategoryRule.normalized_pattern(transaction.merchant)
            next if pattern.blank?

            merchant_stats = stats[pattern]
            merchant_stats[:count] += 1
            merchant_stats[:maximum_cents] = [ merchant_stats[:maximum_cents], transaction.total_amount_cents ].max
          end

        stats
      end
    end
  end
end
