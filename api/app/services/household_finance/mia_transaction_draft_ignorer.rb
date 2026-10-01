module HouseholdFinance
  class MiaTransactionDraftIgnorer
    Result = Struct.new(:success?, :drafts, :response, :errors, keyword_init: true)
    IGNORE_TERMS = /\b(?:ignore|clear|dismiss|remove)\b/i
    ALL_TERMS = /\b(?:all|every|everything)\b|\ball\s+of\s+(?:them|those)\b/i

    def self.explicit_all_request?(value)
      text = value.to_s.squish
      text.match?(IGNORE_TERMS) && text.match?(ALL_TERMS) && text.match?(/\b(?:pending|drafts?|reviews?|transactions?|them|those)\b/i)
    end

    def initialize(household, command:, raw_input:, user: nil, idempotency_key: nil)
      @household = household
      @command = command.to_h.deep_symbolize_keys
      @raw_input = raw_input.to_s.squish
      @user = user || household.household_memberships.includes(:user).order(:id).first&.user
      @idempotency_key = idempotency_key.presence || SecureRandom.uuid
    end

    def call
      return failure("Say explicitly which pending review to ignore, or say ‘ignore all pending reviews.’ Nothing changed.") unless explicit_ignore_request?

      drafts = matching_drafts
      return failure("I could not find a matching pending transaction review. Nothing changed.") if drafts.empty?
      if command[:all_pending] && drafts.length > TransactionDraftBulkResolver::MAX_DRAFTS
        return failure("You have more than #{TransactionDraftBulkResolver::MAX_DRAFTS} pending transaction reviews. I can safely ignore at most #{TransactionDraftBulkResolver::MAX_DRAFTS} at once, so nothing changed. Open Review and resolve them in batches.")
      end
      if !command[:all_pending] && drafts.length > 1
        return failure("I found #{drafts.length} matching pending reviews. Name the merchant with its date or amount so I do not ignore the wrong one. Nothing changed.")
      end

      operation_key = drafts.one? ? "transaction.draft.ignore" : "transaction.drafts.bulk_ignore"
      input = if drafts.one?
        { draft_id: drafts.first.id, source_type: "manual_chat" }
      else
        { draft_ids: drafts.map(&:id), source_type: "manual_chat", year: drafts.first.occurred_on.year }
      end
      Operations::Runner.new(household, user: user).run(
        operation_key: operation_key,
        input: input,
        idempotency_key: idempotency_key,
        source: "mia"
      )
      drafts.each(&:reload)
      count = drafts.length
      total_cents = drafts.sum(&:total_amount_cents)
      response = if count == 1
        draft = drafts.first
        "Ignored the pending #{draft.merchant} review for #{money(draft.total_amount_cents)}. Actuals did not change."
      else
        "Ignored #{count} pending transaction reviews totaling #{money(total_cents)}. Actuals did not change."
      end
      Result.new(success?: true, drafts: drafts, response: response, errors: [])
    end

    private

    attr_reader :household, :command, :raw_input, :user, :idempotency_key

    def explicit_ignore_request?
      return false unless raw_input.match?(IGNORE_TERMS)
      return self.class.explicit_all_request?(raw_input) if command[:all_pending]

      command[:draft_id].to_i.positive? || command[:merchant].present?
    end

    def matching_drafts
      scope = household.transaction_drafts.pending.recent_first
      return scope.limit(TransactionDraftBulkResolver::MAX_DRAFTS + 1).to_a if command[:all_pending]
      return scope.where(id: command[:draft_id].to_i).to_a if command[:draft_id].to_i.positive?

      merchant = command[:merchant].to_s.squish
      return [] if merchant.blank?

      scope = scope.where("LOWER(merchant) = ?", merchant.downcase)
      scope = scope.where(occurred_on: parsed_date(command[:occurred_on])) if command[:occurred_on].present?
      scope = scope.where(total_amount_cents: Money.cents!(command[:amount], message: "Amount must be a number")) if command[:amount].present?
      scope.limit(2).to_a
    rescue ArgumentError
      []
    end

    def parsed_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end

    def failure(message)
      Result.new(success?: false, drafts: [], response: message, errors: [ message ])
    end
  end
end
