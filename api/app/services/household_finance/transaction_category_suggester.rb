module HouseholdFinance
  class TransactionCategorySuggester
    Suggestion = Data.define(:category, :match_status, :match_reason) do
      def matched?
        category.present?
      end
    end

    DINING_TERMS = /\b(mcdonald|restaurant|bar|coffee|latte|takeout|dining|jollibee|cafe|bakery|lunch|dinner|fast\s*food)\b/i
    GROCERY_TERMS = /\b(pay\s*less|payless|grocery|groceries|supermarket|cost\s*u\s*less|costuless|food)\b/i
    TRANSPORT_TERMS = /\b(shell|mobil|76|gas|fuel|transport|transportation)\b/i
    UTILITIES_TERMS = /\b(power|gpa|utility|utilities|water|electric|guam waterworks|internet|docomo|gta)\b/i
    MEDICAL_TERMS = /\b(clinic|medical|doctor|copay|medicine|pharmacy|hospital)\b/i
    HOUSEHOLD_TERMS = /\b(household|cleaning|detergent|soap|paper towel|toilet paper|supplies)\b/i
    TOBACCO_TERMS = /\b(cigarette|cigarettes|tobacco|vape|nicotine)\b/i
    TAX_TERMS = /\b(tax|sales tax)\b/i
    RELIABLE_HEURISTIC_CONFIDENCE = BigDecimal("0.65")

    def initialize(household)
      @household = household
    end

    # Keep the original category-only API for manual Mia transaction drafts.
    def call(**attributes)
      suggestion = suggest(**attributes)
      suggestion.category ||
        stack_category(active_categories, attributes[:stack_key]) ||
        active_categories.find { |category| category.stack_key == "discretionary" } ||
        active_categories.first
    end

    def suggest(merchant:, category_name: nil, stack_key: nil, text: nil, confidence: nil, merchant_fallback: true)
      categories = active_categories
      return no_match("no_active_categories") if categories.empty?

      if (category = exact_category(categories, category_name))
        return matched(category, "exact_category")
      end

      if heuristic_confident?(confidence) && (category = heuristic_category(categories, [ category_name, text ].compact.join(" ")))
        return matched(category, "item_text")
      end

      merchant_rule = merchant_rule_suggestion(merchant, categories)
      return merchant_rule if merchant_rule

      if merchant_fallback && heuristic_confident?(confidence) && (category = heuristic_category(categories, merchant))
        return matched(category, "merchant_text")
      end

      reason = heuristic_confident?(confidence) ? "no_strong_match" : "low_confidence"
      no_match(reason)
    end

    private

    attr_reader :household

    def matched(category, reason)
      Suggestion.new(category: category, match_status: "matched", match_reason: reason)
    end

    def no_match(reason)
      Suggestion.new(category: nil, match_status: "needs_review", match_reason: reason)
    end

    def exact_category(categories, category_name)
      name = normalized(category_name)
      return if name.blank?

      categories.find { |category| normalized(category.name) == name }
    end

    def merchant_rule_suggestion(merchant, categories)
      merchant_text = normalized(merchant)
      return if merchant_text.blank?

      category_ids = categories.map(&:id)
      matching_rules = merchant_category_rules.select do |rule|
        next false unless category_ids.include?(rule.budget_category_id)

        pattern = normalized(rule.merchant_pattern)
        pattern.present? && (merchant_text.include?(pattern) || pattern.include?(merchant_text))
      end
      return if matching_rules.empty?

      matched_categories = matching_rules.filter_map(&:budget_category).uniq(&:id)
      return no_match("ambiguous_merchant_history") if matched_categories.many?

      matched(matched_categories.first, "confirmed_merchant_history")
    end

    def active_categories
      @active_categories ||= household.budget_categories.active.ordered.to_a
    end

    def merchant_category_rules
      @merchant_category_rules ||= household.merchant_category_rules.active.includes(:budget_category).best_first.to_a
    end

    def heuristic_category(categories, text)
      normalized_text = normalized(text)
      if normalized_text.match?(TOBACCO_TERMS)
        category_named(categories, /cigarette|tobacco|smoking|vape/)
      elsif normalized_text.match?(HOUSEHOLD_TERMS)
        category_named(categories, /household|supplies|cleaning|home goods/)
      elsif normalized_text.match?(TAX_TERMS)
        category_named(categories, /tax/)
      elsif normalized_text.match?(UTILITIES_TERMS)
        category_named(categories, /rent|mortgage|fixed|essential|utilities|power|water|internet/)
      elsif normalized_text.match?(TRANSPORT_TERMS)
        category_named(categories, /gas|transport|fuel|car/)
      elsif normalized_text.match?(DINING_TERMS)
        category_named(categories, /dining|restaurant|coffee|takeout|food/)
      elsif normalized_text.match?(GROCERY_TERMS)
        category_named(categories, /grocery|groceries|food/)
      elsif normalized_text.match?(MEDICAL_TERMS)
        category_named(categories, /medical|health|copay|unexpected/)
      end
    end

    def category_named(categories, pattern)
      categories.find { |category| normalized(category.name).match?(pattern) }
    end

    def stack_category(categories, stack_key)
      stack = stack_key.to_s
      return unless stack.in?(BudgetCategory::STACK_KEYS)

      categories.find { |category| category.stack_key == stack }
    end

    def heuristic_confident?(confidence)
      return true if confidence.blank?

      BigDecimal(confidence.to_s) >= RELIABLE_HEURISTIC_CONFIDENCE
    rescue ArgumentError
      false
    end

    def normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end
  end
end
