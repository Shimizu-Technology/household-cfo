module HouseholdFinance
  class TransactionCategorySuggester
    DINING_TERMS = /\b(mcdonald|restaurant|bar|coffee|latte|takeout|dining|jollibee|cafe|bakery|lunch|dinner)\b/i
    GROCERY_TERMS = /\b(pay\s*less|payless|grocery|groceries|supermarket|cost\s*u\s*less|costuless|market)\b/i
    TRANSPORT_TERMS = /\b(shell|mobil|76|gas|fuel|transport|transportation)\b/i
    UTILITIES_TERMS = /\b(power|gpa|utility|utilities|water|electric|guam waterworks|internet|docomo|gta)\b/i
    MEDICAL_TERMS = /\b(clinic|medical|doctor|copay|medicine|pharmacy|hospital)\b/i

    def initialize(household)
      @household = household
    end

    def call(merchant:, category_name: nil, stack_key: nil, text: nil)
      categories = active_categories
      return nil if categories.empty?

      exact_category(categories, category_name) ||
        merchant_rule_category(merchant, categories) ||
        heuristic_category(categories, [ merchant, category_name, text ].compact.join(" "), stack_key) ||
        stack_category(categories, stack_key) ||
        categories.find { |category| category.stack_key == "discretionary" } ||
        categories.first
    end

    private

    attr_reader :household

    def exact_category(categories, category_name)
      name = normalized(category_name)
      return if name.blank?

      categories.find { |category| normalized(category.name) == name } ||
        categories.find { |category| normalized(category.name).include?(name) || name.include?(normalized(category.name)) }
    end

    def merchant_rule_category(merchant, categories)
      merchant_text = normalized(merchant)
      return if merchant_text.blank?

      category_ids = categories.map(&:id)
      merchant_category_rules.find do |rule|
        next false unless category_ids.include?(rule.budget_category_id)

        pattern = normalized(rule.merchant_pattern)
        pattern.present? && (merchant_text.include?(pattern) || pattern.include?(merchant_text))
      end&.budget_category
    end

    def active_categories
      @active_categories ||= household.budget_categories.active.ordered.to_a
    end

    def merchant_category_rules
      @merchant_category_rules ||= household.merchant_category_rules.active.includes(:budget_category).best_first.to_a
    end

    def heuristic_category(categories, text, stack_key)
      normalized_text = text.to_s
      if normalized_text.match?(UTILITIES_TERMS)
        category_named(categories, /rent|mortgage|fixed|essential|utilities|power|water|internet/) || stack_category(categories, "non_discretionary")
      elsif normalized_text.match?(TRANSPORT_TERMS)
        category_named(categories, /gas|transport|fuel|car/)
      elsif normalized_text.match?(GROCERY_TERMS)
        category_named(categories, /grocery|groceries|food/) || stack_category(categories, "discretionary")
      elsif normalized_text.match?(DINING_TERMS)
        category_named(categories, /dining|restaurant|coffee|takeout|food/) || stack_category(categories, "discretionary")
      elsif normalized_text.match?(MEDICAL_TERMS)
        category_named(categories, /medical|health|copay|unexpected/) || stack_category(categories, "sinking_unexpected")
      else
        stack_category(categories, stack_key)
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

    def normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end
  end
end
