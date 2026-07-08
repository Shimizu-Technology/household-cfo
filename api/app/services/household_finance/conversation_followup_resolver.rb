module HouseholdFinance
  class ConversationFollowupResolver
    Result = Struct.new(:message, :direct_answer, :follow_up?, keyword_init: true)

    FOLLOW_UP_PATTERN = /\b(?:what if|does that change|what about|how about|and if|then what|should i|should we|can i|can we|it|they|them|that|this|those|same thing|from earlier|another|also|same place|same merchant|there|tip|plus|add that)\b/i.freeze
    RECALL_PATTERN = /\b(?:remind me|what were we talking about|what was the plan|pick up where we left off|continue where we left off|from earlier|earlier plan)\b/i.freeze
    ACKNOWLEDGMENT_PATTERN = /\A(?:for sure|sounds good|got it|okay|ok|thanks|thank you|appreciate it)(?:[\s,!.]+(?:for sure|sounds good|got it|okay|ok|thanks|thank you|appreciate it|for that|for this|chelu|mia))*[\s,!.]*\z/i.freeze
    MONEY_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    SPENDING_REPORT_PATTERNS = [
      /\bhow much\b.*\b(?:spend|spent|spending|actuals?|transactions?)\b/i,
      /\b(?:how did|how'd)\s+(?:i|we)\s+do\b.*\b(?:this month|last month|month|quarter|year|#{MonthTerms.pattern})\b/i,
      /\b(?:how about|what about)\s+(?:this month|last month|#{MonthTerms.pattern})\b/i,
      /\b(?:show|report)\b.*\b(?:spending|spent|actuals?|transactions?)\b/i,
      /\bwhat\s+(?:did|have)\s+(?:i|we)\s+(?:spend|spent|pay|paid)\b/i,
      /\b(?:spending|spent|actuals?|transactions?)\b.*\b(?:this month|last month|#{MonthTerms.pattern})\b/i
    ].freeze
    MAX_ENRICHED_LENGTH = 1_200

    def initialize(message, conversation_context: nil)
      @message = message.to_s.squish
      @conversation_context = (conversation_context || {}).deep_stringify_keys
    end

    def call
      return Result.new(message: message, direct_answer: nil, follow_up?: false) if message.blank?
      return recall_result if recall_request? && useful_context?
      return empty_recall_result if recall_request?
      return acknowledgment_result if acknowledgment?
      return Result.new(message: enriched_message, direct_answer: nil, follow_up?: true) if topic_continuation?
      return Result.new(message: enriched_message, direct_answer: nil, follow_up?: true) if follow_up? && active_topic.present?

      Result.new(message: message, direct_answer: nil, follow_up?: false)
    end

    private

    attr_reader :message, :conversation_context

    def recall_result
      topics = open_topics.presence || [ active_topic ].compact
      topic_lines = topics.first(4).map do |topic|
        parts = [ topic["title"], topic["amount_label"], topic["latest_mia_summary"], topic["next_move"] ].compact_blank
        parts.join(" — ")
      end
      summary = topic_lines.to_sentence.presence || rolling_summary
      answer = "Here is the conversation context I can pick up from: #{summary}. This is conversation memory, not financial truth; confirmed actuals, balances, and plan amounts still come from approved records. Next CFO move: tell me which topic you want to continue, or send the missing amount and due date for the active decision."

      Result.new(message: message, direct_answer: answer, follow_up?: true)
    end

    def empty_recall_result
      answer = "I do not have an open chat topic to resume after the clear. Conversation continuity is context only, not financial truth; confirmed actuals, balances, and plan amounts still come from approved records. Next CFO move: tell me the decision, bill, purchase, or transaction you want to work through next."

      Result.new(message: message, direct_answer: answer, follow_up?: false)
    end

    def enriched_message
      topic = active_topic
      prefix = [
        "Follow-up to previous #{topic['type']} topic.",
        "Topic: #{topic['title']}.",
        topic["subject"].present? ? "Subject: #{topic['subject']}." : nil,
        topic["amount_label"].present? ? "Prior amount discussed: #{topic['amount_label']}." : nil,
        topic["next_move"].present? ? "Prior next move: #{topic['next_move']}." : nil
      ].compact.join(" ")

      "#{prefix} Current follow-up: #{message}".truncate(MAX_ENRICHED_LENGTH, omission: "…")
    end

    def acknowledgment_result
      answer = "You got it — when you are ready, send me the next amount, due date, transaction, or decision and I’ll keep the coaching grounded in approved household numbers."

      Result.new(message: message, direct_answer: answer, follow_up?: false)
    end

    def useful_context?
      active_topic.present? || open_topics.any? || rolling_summary.present?
    end

    def recall_request?
      message.match?(RECALL_PATTERN)
    end

    def acknowledgment?
      message.match?(ACKNOWLEDGMENT_PATTERN)
    end

    def follow_up?
      message.match?(FOLLOW_UP_PATTERN) && !strong_new_topic?
    end

    def topic_continuation?
      return false if active_topic.blank? || strong_new_topic?

      case active_topic["type"].to_s
      when "readiness_plan"
        message.match?(/\b(?:create|make|build)\s+(?:me\s+|us\s+)?(?:a\s+)?(?:concrete\s+|step(?: |-)?by(?: |-)?step\s+)?plan\b|\b(?:what are the steps|what should we do next|how do we do it|next step|30 day|this week)\b/i)
      when "transaction_draft"
        message.match?(MONEY_PATTERN) && message.match?(/\b(?:another|also|same place|same merchant|there|tip|plus|add|extra|fee)\b/i)
      else
        false
      end
    end

    def strong_new_topic?
      normalized = message.downcase
      normalized.match?(/\b(?:new question|different question|switch topics|unrelated)\b/) ||
        normalized.match?(/\b(?:my cousin|car registration|car repair|payday loan|balance transfer|leave my job|business income|pending drafts?|i spent|we spent)\b/) ||
        spending_report_question?
    end

    def spending_report_question?
      SPENDING_REPORT_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    def active_topic
      topic = conversation_context["active_topic"].to_h
      topic.presence
    end

    def open_topics
      Array(conversation_context["open_topics"])
    end

    def rolling_summary
      conversation_context["rolling_summary"].presence
    end
  end
end
