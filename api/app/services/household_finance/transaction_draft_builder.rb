module HouseholdFinance
  class TransactionDraftBuilder
    AMOUNT_PATTERN = /\$\s*(#{Money::CHAT_NUMBER_SOURCE}(?![\d,])#{Money::CHAT_THOUSANDS_SOURCE}?)/.freeze
    BARE_SPEND_AMOUNT_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought)\s+(#{Money::CHAT_NUMBER_SOURCE}(?![\d,])#{Money::CHAT_THOUSANDS_SOURCE}?)(?:\s+(?:at|from|to|for|on|today|yesterday)\b|[.,;!?]|\z)/i.freeze
    SPEND_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought)\b/i.freeze
    NON_EXPENSE_MOVEMENT_PATTERN = /\b(?:transfer(?:red|ring)?|withdr(?:aw|ew|awn|awal)|deposit(?:ed)?|refund(?:ed)?|reimburse(?:d|ment)?|(?:credit\s*card|card|loan|debt)\s+payment|balance\s+(?:adjustment|correction))\b|\bpaid\b.{0,50}\b(?:visa|mastercard|amex|credit\s*card|loan)\b|\b(?:got|get|gets|received|receive)\s+(?:\$?\s*\d[\d,.]*k?\s*(?:dollars?|bucks)?\s+)?back\b|\b\d[\d,.]*\s*(?:dollars?|bucks)?\s+back\s+from\b|\b(?:paid|gave|sent)\s+me\s+(?:back\b|\$?\d)/i.freeze
    EXPLICIT_PURCHASE_PATTERN = /\b(?:(?:i|we)\s+)?(?:spent|charged|bought|purchased)\s+\$?\s*(#{Money::CHAT_NUMBER_SOURCE}#{Money::CHAT_THOUSANDS_SOURCE}?)\s+(?:at|from)\s+([^.,;!?$]+?)(?=\s+(?:for|on|today|yesterday)\b|\s+(?:and|then|&)\s+(?:(?:i|we)\s+)?(?:put|paid|transferred|moved|deposited|added|sent|saved|withdrew|invested)\b|[.,;!?]|\z)/i.freeze
    MERCHANT_PATTERNS = [
      /\b(?:at|from|to)\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i,
      /\b(?:spent|paid|charged|bought)\s+\$?\s*\d[\d,.]*(?:k\b|\s*thousand\b)?\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i
    ].freeze

    # Transfers, refunds, debt payments, savings deposits and investment buys move
    # money without being an expense; only a separate store purchase can be drafted.
    def self.non_expense_movement?(value)
      value.to_s.match?(NON_EXPENSE_MOVEMENT_PATTERN) || MoneyMovementText.non_expense?(value)
    end

    # A model-proposed amount is allowed beside a deposit or investment buy only when it
    # is the separate purchase's own amount ("spent $30 on groceries and put $50 in savings").
    def self.mixed_spend_amount?(value, amount)
      remainder = MoneyMovementText.without_non_expense(value)
      return false if non_expense_movement?(remainder)

      cents = Money.chat_cents(amount.to_s.delete("$ "))
      cents.positive? && MoneyMovementText.separate_spend_amounts(value).include?(cents)
    end

    def self.explicit_purchase_details(value)
      match = value.to_s.match(EXPLICIT_PURCHASE_PATTERN)
      return unless match

      merchant = match[2].to_s.squish.truncate(120, omission: "…")
      return if merchant.blank? || MoneyMovementText.investment_merchant?(merchant)

      { amount: Money.chat_amount_text(match[1]), merchant: merchant }
    end

    def initialize(household, message, user:, annual_budget_manager: nil, plan_prepared: false, raw_input: nil, idempotency_key: nil)
      @household = household
      @message = message.to_s.squish
      @raw_input = raw_input.to_s.squish.presence || @message
      # Savings-deposit and investment clauses never feed the expense amount or merchant.
      @spend_input = MoneyMovementText.without_non_expense(@raw_input)
      @draft_text = MoneyMovementText.without_non_expense(current_follow_up_text.presence || @raw_input)
      @explicit_purchase = self.class.explicit_purchase_details(@spend_input) if self.class.non_expense_movement?(@spend_input)
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

    attr_reader :household, :message, :raw_input, :spend_input, :draft_text, :explicit_purchase

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
      [ draft_text, MoneyMovementText.without_non_expense(message), merchant ].join(" ")
    end

    def transaction_like?
      return false if self.class.non_expense_movement?(spend_input) && explicit_purchase.blank?

      explicit_spend = amount_match.present? && (draft_text.match?(SPEND_PATTERN) || MiaCoachAnswerer.subjectless_spend_report?(draft_text))
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
      @amount_cents ||= Money.chat_cents(amount_match&.[](1))
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
          match = draft_text.match(pattern) || spend_input.match(pattern)
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
