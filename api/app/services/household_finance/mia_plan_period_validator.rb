# frozen_string_literal: true

module HouseholdFinance
  # Validate the period as well as the amount. An annual plan contains monthly
  # cells; its year is never the period of a selected category's figures.
  class MiaPlanPeriodValidator
    YEARLY = /\b(?:this year|for the year|per year|a year|yearly|annually|annual(?! plan))\b/i

    def initialize(packet)
      @summary = packet[:annual_plan_summary].to_h
    end

    def mismatch?(content)
      period = @summary[:category_period].to_h
      return false unless period[:unit] == "month"

      categories = Array(@summary[:top_categories])
      content.split(::Mia::ResponseShapePolicy::SENTENCE_BOUNDARY).any? do |sentence|
        sentence.split(/;|\b(?:and|but|while)\b/i).any? do |clause|
          amounts = clause.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN).flatten.map { |amount| Money.chat_cents(amount) }
          matching_categories = categories.select do |category|
            category.values_at(:planned, :actual, :remaining).compact.any? { |amount| amounts.include?(Money.cents(amount)) }
          end
          known = matching_categories.one? || matching_categories.any? do |category|
            named = clause.match?(/\b(?:plan|budget)\b/i) || clause.downcase.include?(category[:name].to_s.downcase)
            named
          end
          next false unless known
          monthly_cadence = clause.match?(/\b(?:monthly|per month|a month|each month|every month)\b/i)
          next true if clause.match?(YEARLY) && !monthly_cadence

          named_months = Date::ABBR_MONTHNAMES.compact.each_with_index.filter_map do |name, index|
            # Lowercase "may" is often a verb rather than a month. Require a
            # date context for that spelling while accepting other month cases.
            matches = if name == "May"
              clause.match?(/\bMay\b/) || clause.match?(/\b(?:in|for|during|through|until|from|of)\s+may\b|\bmay\s+20\d{2}\b/i)
            else
              clause.match?(/\b#{name}(?:#{Date::MONTHNAMES[index + 1].delete_prefix(name)})?\b/i)
            end
            index + 1 if matches
          end
          named_months.any? { |month| month != period[:month] } || clause.scan(/\b20\d{2}\b/).any? { |year| year.to_i != period[:year] }
        end
      end
    end
  end
end
