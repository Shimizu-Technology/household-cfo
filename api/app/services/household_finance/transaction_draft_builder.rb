module HouseholdFinance
  class TransactionDraftBuilder
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    BARE_SPEND_AMOUNT_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\s+((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])(?:\s+(?:at|from|to|for|on|today|yesterday)\b|[.,;!?]|\z)/i.freeze
    SPEND_PATTERN = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\b/i.freeze
    MERCHANT_PATTERNS = [
      /\b(?:at|from|to)\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i,
      /\b(?:spent|paid|charged|bought)\s+\$?\s*\d[\d,.]*\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i
    ].freeze

    def initialize(household, message, annual_budget_manager: nil, plan_prepared: false, raw_input: nil)
      @household = household
      @message = message.to_s.squish
      @raw_input = raw_input.to_s.squish.presence || @message
      @draft_text = current_follow_up_text.presence || @raw_input
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
        raw_input: raw_input,
        draft_payload: {
          parser: "simple_spend_v1",
          message: raw_input,
          parser_context: message == raw_input ? nil : message,
          amount_text: amount_match&.[](0),
          suggested_category_reason: suggested_category_reason
        }
      )
    rescue ActiveRecord::RecordInvalid => e
      log_invalid_draft(e.record)
      nil
    end

    private

    attr_reader :household, :message, :raw_input, :draft_text

    def log_invalid_draft(record)
      Rails.logger.warn(
        "TransactionDraftBuilder could not create draft " \
          "household_id=#{household.id} errors=#{record.errors.full_messages.to_sentence}"
      )
    end

    def ensure_plan!
      return if @plan_prepared

      @annual_budget_manager.ensure_plan!
      @plan_prepared = true
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
      explicit_spend = amount_match.present? && draft_text.match?(SPEND_PATTERN)
      tab_total = draft_text.match?(AMOUNT_PATTERN) && draft_text.match?(/\bmy\s+tab\s+(?:is|was)\b/i)
      contextual_spend = transaction_follow_up_context? && amount_match.present? && draft_text.match?(/\b(?:another|also|same place|same merchant|there|tip|plus|add|extra|fee)\b/i)

      explicit_spend || tab_total || contextual_spend
    end

    def amount_match
      @amount_match ||= draft_text.match(AMOUNT_PATTERN) || draft_text.match(BARE_SPEND_AMOUNT_PATTERN) || message.match(BARE_SPEND_AMOUNT_PATTERN)
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

    def suggested_category
      @suggested_category ||= begin
        categories = household.budget_categories.active.ordered.to_a
        return nil if categories.empty?

        named_match = categories.find { |category| normalized_text(category_match_text).include?(normalized_text(category.name)) }
        return named_match if named_match

        merchant_category(categories) || categories.find { |category| category.stack_key == "discretionary" } || categories.first
      end
    end

    def merchant_category(categories)
      text = normalized_text([ merchant, draft_text, message ].join(" "))
      if text.match?(/\b(rent|mortgage|power|gpa|utility|utilities|water|electric)\b/)
        category_named(categories, /rent|mortgage|fixed|essential|utilities|power/)
      elsif text.match?(/\b(shell|gas|fuel|transport|transportation)\b/)
        category_named(categories, /gas|transport|fuel/)
      elsif text.match?(/\b(mcdonald|restaurant|bar|coffee|latte|takeout|dining|jollibee|cafe|bakery)\b/)
        category_named(categories, /dining|restaurant|coffee|takeout|food/) || discretionary_category(categories)
      elsif text.match?(/\b(pay\s*less|payless|grocery|groceries|supermarket|cost\s*u\s*less|costuless)\b/)
        category_named(categories, /grocery|groceries|food/) || category_named(categories, /fixed|essential/)
      elsif text.match?(/\b(basketball|league|sports?|school supplies|uniforms?|kids?)\b/)
        category_named(categories, /kids|school|activities|back/) || discretionary_category(categories)
      elsif text.match?(/\b(clinic|medical|doctor|copay|medicine|pharmacy)\b/)
        category_named(categories, /medical|health|copay|unexpected/)
      end
    end

    def category_named(categories, pattern)
      categories.find { |category| normalized_text(category.name).match?(pattern) }
    end

    def discretionary_category(categories)
      categories.find { |category| category.stack_key == "discretionary" }
    end

    def suggested_category_reason
      suggested_category ? "Matched #{suggested_category.name} from current budget categories." : "No active category matched."
    end

    def normalized_text(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end
  end
end
