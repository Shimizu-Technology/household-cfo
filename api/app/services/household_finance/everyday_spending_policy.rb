module HouseholdFinance
  # Broad spending groups have a default, rather than a new question for every
  # shop. A participant's explicit split or reviewed choice owns any exception.
  class EverydaySpendingPolicy
    def self.family(value)
      families(value).first
    end

    def self.families(value)
      text = value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
      return [] if text.match?(/\bgas\s+(?:co|company|utility|services?)\b/)
      result = []
      result << :groceries if text.match?(TransactionCategorySuggester::GROCERY_TERMS)
      result << :fuel if text.match?(Regexp.union(TransactionCategorySuggester::TRANSPORT_TERMS, TransactionCategorySuggester::TRANSPORT_CATEGORY_NAMES))
      result
    end

    def initialize(household)
      @household = household
    end

    def suggestion(merchant:, text: nil)
      family = self.class.family([ merchant, text ].compact.join(" "))
      return unless family
      categories = @categories ||= @household.budget_categories.active.ordered.to_a
      # One explicit answer covers other shops serving that same purpose.
      @rules ||= @household.merchant_category_rules.active.includes(:budget_category).to_a
      rules = @rules.select do |rule|
        self.class.family(rule.merchant_pattern) == family && categories.include?(rule.budget_category) && similar_purpose?(rule.budget_category, family)
      end
      choices = rules.map(&:budget_category).uniq
      @reviewed_choices ||= SourceReviewVersion.where(id: SourceReviewHead.where(household: @household).select(:approved_version_id), disposition: "include")
        .where.not(budget_category_id: nil).order(:id).pluck(:merchant, :budget_category_id)
      reviewed = @reviewed_choices.reverse.find { |name, id| self.class.family(name) == family && categories.any? { |category| category.id == id && similar_purpose?(category, family) } }
      return { category: categories.find { |category| category.id == reviewed[1] }, reason: "confirmed_spending_purpose" } if reviewed
      return { category: choices.sole, reason: "confirmed_spending_purpose" } if choices.one?
      return { category: nil, reason: "check_participant_split" } if choices.many?
      if (preference = applied_preference(family))
        stack = preference["group"] == "fixed" ? "non_discretionary" : "discretionary"
        matching = categories.select { |category| category.stack_key == stack && SavingsChallenge::Daily::ReviewCategories.broad?(category) }
        return { category: matching.one? ? matching.sole : nil, reason: matching.one? ? "confirmed_setup_spending_purpose" : "check_participant_split" }
      end
      return { category: nil, reason: "check_participant_split" } if stated_different_split?(family, categories)
      everyday = categories.select { |category| category.stack_key == "discretionary" && SavingsChallenge::Daily::ReviewCategories.broad?(category) }
      return unless everyday.one?
      { category: everyday.sole, reason: "everyday_spending_default" }
    end

    private

    def similar_purpose?(category, family)
      SavingsChallenge::Daily::ReviewCategories.broad?(category) || self.class.families(category.name).include?(family)
    end

    def stated_different_split?(family, categories)
      return true if categories.any? { |category| category.stack_key != "discretionary" && self.class.families(category.name).include?(family) &&
        !category.name.downcase.match?(TransactionCategorySuggester::NON_TRIP_VEHICLE_NAMES) }
      false
    end

    def applied_preference(family)
      # Only reviewed, applied structured preferences establish an exception.
      # Never reinterpret a source prompt with language-pattern rules.
      @setup_preferences ||= @household.mia_action_drafts.where(status: "applied", draft_type: %w[household_setup action_plan])
        .order(:id).pluck(:metadata).flat_map { |metadata| Array(metadata["spending_preferences"]) }
      @setup_preferences.reverse.find { |preference| preference["family"] == family.to_s }
    end
  end
end
