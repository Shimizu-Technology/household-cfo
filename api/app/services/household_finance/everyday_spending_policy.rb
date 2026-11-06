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
      return { category: nil, reason: "check_participant_split" } if choices.many? || stated_different_split?(family, categories)
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
      # Only applied setup words establish a different split. An extracted bank
      # label and an unapplied chat proposal cannot change this rule.
      @setup_prompts ||= @household.mia_action_drafts.where(status: "applied", draft_type: %w[household_setup action_plan]).pluck(:source_prompt)
      @setup_prompts.any? do |prompt|
        prompt.to_s.split(/[.!?;]|\bbut\b/i).any? do |clause|
          self.class.families(clause).include?(family) && clause.match?(/\b(?:fixed|essentials|bills)\b/i) &&
            clause.match?(/\b(?:includes?|including|covers?|under|within|part of|counted in)\b/i) && !clause.match?(/\b(?:not|don['’]?t|exclude)\b/i)
        end
      end
    end
  end
end
