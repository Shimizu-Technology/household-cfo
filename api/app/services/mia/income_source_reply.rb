module Mia
  # A terse answer to a reviewed source setup question keeps its household scope.
  module IncomeSourceReply
    module_function

    def matches?(message, session:)
      topic = session.active_topic.to_h.deep_symbolize_keys
      return false unless topic[:schema_version].to_i >= 2 && topic[:status] == "needs_clarification" && topic.dig(:action, :type) == "create_income_source"
      text = message.to_s.squish
      return true if text.match?(HouseholdFinance::MiaIntentResolver::GUIDED_MONEY_REPLY_PATTERN)
      text.match?(/\A(?:a\s+|an\s+)?(?:job|business|rental|passive|bonus|other)(?:\s+income(?:\s+source)?)?(?:\s*[:,.!-]|\z)/i)
    end
  end
end
