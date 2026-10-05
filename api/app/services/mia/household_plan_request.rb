# frozen_string_literal: true

module Mia
  # A challenge entry and a household plan edit are different facts. Choose the
  # surface before asking the model to interpret the edit, never from its output.
  class HouseholdPlanRequest
    WRITE = /\b(?:set|change|update|adjust|make|edit|reduce|transfer|shift|create|add|rename|archive|restore|remove|delete|schedule|end|stop|increase|decrease|lower|raise|move|reclassify|recategorize|link|unlink|reconcile)\b/i.freeze
    INCOME_REPORT = /\b(?:my|our)\s+(?:primary\s+|business\s+|monthly\s+)?(?:income|salary|take[ -]?home pay|paycheck)\s+(?:(?:is|will be|changed to|has changed to)\s+)?(?:now\s+)?\$\s*\d/i.freeze
    CHALLENGE = /\b(?:challenge|bog|90[ -]day|baseline|check[ -]?in|reserved|contribution|withdrawal|optional (?:card|debt)|card review|savings (?:target|goal|progress|plan))\b/i.freeze
    HOUSEHOLD = /\b(?:household|budget|category|categories|allocation|income|salary|paycheck|income source|account|asset|tracked goal|expense stack|runway)\b/i.freeze
    AMBIGUOUS = /\b(?:goal|debt|credit card|card balance|minimum payment)\b/i.freeze
    ACTION_INTENTS = %w[action_plan budget_action household_action income_action debt_action asset_action goal_action pending_drafts].freeze
    ACTION_TYPES = (HouseholdFinance::MiaIntentResolver::ACTION_TYPES - %w[none create_transaction_draft update_transaction_draft ignore_transaction_drafts]).freeze

    def self.classify(message, household: nil)
      text = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      # Reporting a purchase/reservation keeps the challenge intake even when a
      # merchant, goal or account happens to share a household record's label.
      return :challenge if text.match?(/\A(?:i|we)\s+(?:have\s+)?(?:set aside|saved|spent|bought|paid|withdrew|withdrawn|contributed)\b/i)
      if text.match?(HouseholdFinance::MiaIntentResolver::HYPOTHETICAL_PATTERN) &&
          text.match?(/\bhousehold\b/i) && text.match?(HOUSEHOLD) && !text.match?(CHALLENGE)
        return :household_read
      end
      if text.match?(/\A(?:please\s+)?(?:show|tell me|what|which|how|explain)\b/i) && !text.match?(WRITE) &&
          text.match?(/\bhousehold\b/i) && text.match?(/\b(?:budget|categories|category|spending|plan)\b/i) && !text.match?(CHALLENGE)
        return :household_read
      end
      return :challenge unless text.match?(WRITE) || text.match?(INCOME_REPORT)
      return :challenge if FinancialReadOnlyRequest.matches?(text)
      return :ambiguous if text.match?(CHALLENGE) && text.match?(/\bhousehold\b/i)
      matched_topics = household ? saved_topics(household, text) : []
      return matched_topics.any? ? :ambiguous : :challenge if text.match?(CHALLENGE)
      return :household if text.match?(HOUSEHOLD) || text.match?(INCOME_REPORT)
      return :household if matched_topics.one? && matched_topics.first != :debt
      return :ambiguous if matched_topics.any?
      return :ambiguous if text.match?(AMBIGUOUS)

      :challenge
    end

    def self.saved_topics(household, text)
      { spending: household.budget_categories.pluck(:name), income: household.income_sources.pluck(:label),
        accounts: household.accounts.pluck(:label), goals: household.goals.tracked.pluck(:label),
        debt: household.debts.pluck(:label) }.filter_map do |topic, labels|
        topic if labels.any? { |label| label.present? && text.match?(/(?<!\w)#{Regexp.escape(label)}(?!\w)/i) }
      end
    end

    def self.allowed_intent?(result)
      return false unless result && ACTION_INTENTS.include?(result.intent)
      return true if result.clarification?
      if result.intent == "action_plan"
        actions = Array(result.write_plan.to_h[:actions])
        return actions.any? && actions.all? { |entry| ACTION_TYPES.include?(entry.to_h.dig(:action, :type).to_s) }
      end

      ACTION_TYPES.include?(result.action.to_h[:type].to_s)
    end

    def self.allowed_read_intent?(result)
      result && !result.actionable? && result.intent.in?(HouseholdFinance::MiaIntentResolver::READ_ONLY_INTENTS)
    end

    def self.clarification
      "Do you mean your household plan or your savings challenge? For example, say ‘Update my household debt’ or ‘Change my challenge savings target.’ They use separate reviewed records; nothing has changed."
    end
  end
end
