module HouseholdFinance
  class TransactionDraftBuilder
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    SPEND_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\b/i.freeze
    MERCHANT_PATTERNS = [
      /\b(?:at|from|to)\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i,
      /\b(?:spent|paid|charged)\s+\$?\s*\d[\d,.]*\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i
    ].freeze

    def initialize(household, message, annual_budget_manager: nil, plan_prepared: false)
      @household = household
      @message = message.to_s.squish
      prepared_manager = annual_budget_manager if annual_budget_manager&.year == occurred_on.year
      @annual_budget_manager = prepared_manager || AnnualBudgetManager.new(household, year: occurred_on.year)
      @plan_prepared = plan_prepared && prepared_manager.present?
    end

    def call
      return nil unless transaction_like?
      return nil unless amount_cents.positive?

      ensure_plan!
      household.transaction_drafts.create!(
        occurred_on: occurred_on,
        merchant: merchant,
        total_amount_cents: amount_cents,
        budget_category: suggested_category,
        source_type: "manual_chat",
        status: "pending",
        confidence: 0.72,
        raw_input: message,
        draft_payload: {
          parser: "simple_spend_v1",
          message: message,
          amount_text: amount_match&.[](0),
          suggested_category_reason: suggested_category_reason
        }
      )
    rescue ActiveRecord::RecordInvalid
      nil
    end

    private

    attr_reader :household, :message

    def ensure_plan!
      return if @plan_prepared

      @annual_budget_manager.ensure_plan!
      @plan_prepared = true
    end

    def transaction_like?
      message.match?(AMOUNT_PATTERN) && (message.match?(SPEND_PATTERN) || message.match?(/\bmy\s+tab\s+(?:is|was)\b/i))
    end

    def amount_match
      @amount_match ||= message.match(AMOUNT_PATTERN)
    end

    def amount_cents
      @amount_cents ||= Money.cents(amount_match&.[](1).to_s.delete(","))
    end

    def occurred_on
      @occurred_on ||= if message.match?(/\byesterday\b/i)
        Date.yesterday
      else
        Date.current
      end
    end

    def merchant
      @merchant ||= begin
        MERCHANT_PATTERNS.each do |pattern|
          match = message.match(pattern)
          next unless match

          candidate = clean_merchant(match[1])
          return candidate if candidate.present?
        end
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

    def suggested_category
      @suggested_category ||= begin
        categories = household.budget_categories.active.ordered.to_a
        return nil if categories.empty?

        named_match = categories.find { |category| normalized_text(message).include?(normalized_text(category.name)) }
        return named_match if named_match

        merchant_category(categories) || categories.find { |category| category.stack_key == "discretionary" } || categories.first
      end
    end

    def merchant_category(categories)
      text = normalized_text([ merchant, message ].join(" "))
      if text.match?(/\b(mcdonald|restaurant|bar|coffee|latte|takeout|dining)\b/)
        categories.find { |category| normalized_text(category.name).match?(/dining|food|flexible|coffee/) }
      elsif text.match?(/\b(payless|grocery|groceries|supermarket)\b/)
        categories.find { |category| normalized_text(category.name).match?(/grocery|groceries|food|flexible/) }
      end
    end

    def suggested_category_reason
      suggested_category ? "Matched #{suggested_category.name} from current budget categories." : "No active category matched."
    end

    def normalized_text(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end
  end
end
