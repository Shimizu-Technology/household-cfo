module HouseholdFinance
  class TransactionDraftBuilder
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    BARE_SPEND_AMOUNT_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought)\s+((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])(?:\s+(?:at|from|to|for|on|today|yesterday)\b|[.,;!?]|\z)/i.freeze
    SPEND_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought)\b/i.freeze
    NON_EXPENSE_MOVEMENT_PATTERN = /\b(?:transfer(?:red|ring)?|withdr(?:aw|ew|awn|awal)|deposit(?:ed)?|refund(?:ed)?|reimburse(?:d|ment)?|(?:credit\s*card|card|loan|debt)\s+payment|balance\s+(?:adjustment|correction))\b|\bpaid\b.{0,50}\b(?:visa|mastercard|amex|credit\s*card|loan)\b/i.freeze
    EXPLICIT_PURCHASE_PATTERN = /\b(?:(?:i|we)\s+)?(?:spent|charged|bought|purchased)\s+\$?\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)\s+(?:at|from)\s+([^.,;!?$]+?)(?=\s+(?:for|on|today|yesterday)\b|[.,;!?]|\z)/i.freeze
    MERCHANT_PATTERNS = [
      /\b(?:at|from|to)\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i,
      /\b(?:spent|paid|charged|bought)\s+\$?\s*\d[\d,.]*\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i
    ].freeze

    def self.non_expense_movement?(value)
      value.to_s.match?(NON_EXPENSE_MOVEMENT_PATTERN)
    end

    def self.explicit_purchase_details(value)
      match = value.to_s.match(EXPLICIT_PURCHASE_PATTERN)
      return unless match

      merchant = match[2].to_s.squish.truncate(120, omission: "…")
      return if merchant.blank?

      { amount: match[1].delete(","), merchant: merchant }
    end

    def initialize(household, message, user:, annual_budget_manager: nil, plan_prepared: false, raw_input: nil, idempotency_key: nil)
      @household = household
      @message = message.to_s.squish
      @raw_input = raw_input.to_s.squish.presence || @message
      @draft_text = current_follow_up_text.presence || @raw_input
      @explicit_purchase = self.class.explicit_purchase_details(@raw_input) if self.class.non_expense_movement?(@raw_input)
      @user = user
      @idempotency_key = idempotency_key.presence || SecureRandom.uuid
    end

    def call
      return nil unless transaction_like?
      return nil unless amount_cents.positive?

      Operations::Runner.new(household, user: @user).run(
        operation_key: "transaction.draft.create",
        input: {
          occurred_on: occurred_on.iso8601,
          merchant: merchant,
          amount_cents: amount_cents,
          source_type: "manual_chat",
          raw_input: raw_input,
          category_context: category_match_text
        },
        idempotency_key: @idempotency_key,
        source: "mia"
      ).subject
    rescue ActiveRecord::RecordInvalid => e
      log_invalid_draft(e.record)
      nil
    end

    private

    attr_reader :household, :message, :raw_input, :draft_text, :explicit_purchase

    def log_invalid_draft(record)
      Rails.logger.warn(
        "TransactionDraftBuilder could not create draft " \
          "household_id=#{household.id} errors=#{record.errors.full_messages.to_sentence}"
      )
    end

    def current_follow_up_text
      match = message.match(/\bCurrent follow-up:\s*(.+)\z/i)
      match&.[](1)&.squish
    end

    def transaction_follow_up_context?
      message.match?(/\AFollow-up to previous transaction_draft topic\./i) || message.match?(/\bTopic:\s*Reported spending\./i)
    end

    def context_subject
      subject = message.match(/\bSubject:\s*([^.]*)\./)&.[](1)&.squish
      return if subject.blank? || subject.match?(/reported spending/i)

      subject.truncate(120, omission: "…")
    end

    def category_match_text
      [ draft_text, message, merchant ].join(" ")
    end

    def transaction_like?
      return false if self.class.non_expense_movement?(raw_input) && explicit_purchase.blank?

      explicit_spend = amount_match.present? && draft_text.match?(SPEND_PATTERN)
      tab_total = draft_text.match?(AMOUNT_PATTERN) && draft_text.match?(/\bmy\s+tab\s+(?:is|was)\b/i)
      contextual_spend = transaction_follow_up_context? && amount_match.present? && draft_text.match?(/\b(?:another|also|same place|same merchant|there|tip|plus|add|extra|fee)\b/i)

      explicit_spend || tab_total || contextual_spend
    end

    def amount_match
      @amount_match ||= if explicit_purchase
        "$#{explicit_purchase.fetch(:amount)}".match(AMOUNT_PATTERN)
      else
        draft_text.match(AMOUNT_PATTERN) || draft_text.match(BARE_SPEND_AMOUNT_PATTERN) || message.match(BARE_SPEND_AMOUNT_PATTERN)
      end
    end

    def amount_cents
      @amount_cents ||= Money.cents(amount_match&.[](1).to_s.delete(","))
    end

    def occurred_on
      @occurred_on ||= if draft_text.match?(/\byesterday\b/i)
        Date.yesterday
      else
        Date.current
      end
    end

    def merchant
      @merchant ||= begin
        return explicit_purchase.fetch(:merchant) if explicit_purchase

        MERCHANT_PATTERNS.each do |pattern|
          match = draft_text.match(pattern) || raw_input.match(pattern)
          next unless match

          candidate = clean_merchant(match[1])
          return candidate if candidate.present?
        end
        return context_subject if transaction_follow_up_context? && context_subject.present?

        "Manual spend"
      end
    end

    def clean_merchant(value)
      value.to_s
        .gsub(AMOUNT_PATTERN, "")
        .gsub(/\b(?:for|on|today|yesterday)\b.*\z/i, "")
        .squish
        .truncate(120, omission: "…")
    end
  end
end
