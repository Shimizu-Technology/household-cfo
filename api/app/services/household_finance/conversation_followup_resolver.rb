module HouseholdFinance
  class ConversationFollowupResolver
    Result = Struct.new(:message, :direct_answer, :follow_up?, keyword_init: true)

    FOLLOW_UP_PATTERN = /\b(?:what if|does that change|what about|how about|and if|then what|should i|should we|can i|can we|it|they|them|that|this|those|same thing|from earlier|another|also|same place|same merchant|there|tip|plus|add that)\b/i.freeze
    RECALL_PATTERN = /\b(?:remind me|what were we(?: just)? talking about|what did we(?: just)? talk about|what were we(?: just)? doing|what did we(?: just)? do|what was the plan|pick up where we left off|continue where we left off|from earlier|earlier plan)\b/i.freeze
    ACKNOWLEDGMENT_PATTERN = /\A(?:for sure|sounds good|got it|okay|ok|thanks|thank you|appreciate it)(?:[\s,!.]+(?:for sure|sounds good|got it|okay|ok|thanks|thank you|appreciate it|for that|for this|chelu|mia))*[\s,!.]*\z/i.freeze
    CONFIRMATION_PATTERN = /\A(?:yes|yeah|yep|yup|please|ok|okay|sure|for sure|go ahead)(?:[\s,!.]+(?:please|do that|do it|draft that|make that change|go ahead|yes|yeah|ok|okay|sure))*[\s,!.]*\z|\A(?:do that|do it|draft that|make that change|please do that|please do it)[\s,!.]*\z/i.freeze
    MONEY_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    CONDITIONAL_MONTHLY_INCOME_AMOUNT_PATTERN = /\b(?:if|given(?:\s+that)?|assuming|suppose|supposing|let['’]?s\s+say)\b.{0,120}\b(?:(?:our|my|the)\s+)?(?:monthly\s+income|income\s+(?:per|each)\s+month|take(?:\s|-)?home(?:\s+pay)?|bring\s+home)\b(?:\s+(?:is|was|were|equals?|of|became|becomes))?\s*(?:about|around|approximately|roughly)?\s*\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?!\d|,\d)/i.freeze
    SAVINGS_SURPLUS_QUESTION_PATTERN = /\b(?:save|saving|savings|surplus|left\s+over|leftover)\b/i.freeze
    SPENDING_REPORT_PATTERNS = [
      /\bhow much\s+(?:did|have)\s+(?:i|we)\s+(?:spend|spent|pay|paid)\b/i,
      /\bhow much\s+(?:was|were)\b.*\b(?:spent|spending|actuals?|transactions?)\b/i,
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

    def self.complete_conditional_income_question?(message)
      text = message.to_s.squish
      text.match?(CONDITIONAL_MONTHLY_INCOME_AMOUNT_PATTERN) && text.match?(SAVINGS_SURPLUS_QUESTION_PATTERN)
    end

    def call
      return Result.new(message: message, direct_answer: nil, follow_up?: false) if message.blank?
      if MiaCoachAnswerer.prompt_injection?(active_topic.to_h["latest_user_context"])
        return Result.new(message: message, direct_answer: nil, follow_up?: false)
      end
      return recall_result if recall_request? && useful_context?
      return empty_recall_result if recall_request?
      return Result.new(message: enriched_message, direct_answer: nil, follow_up?: true) if confirmation? && active_topic.present?
      return acknowledgment_result if acknowledgment?
      return Result.new(message: enriched_message, direct_answer: nil, follow_up?: true) if topic_continuation?
      return Result.new(message: enriched_message, direct_answer: nil, follow_up?: true) if follow_up? && active_topic.present?

      Result.new(message: message, direct_answer: nil, follow_up?: false)
    end

    private

    attr_reader :message, :conversation_context

    def recall_result
      topics = open_topics.presence || [ active_topic ].compact
      topic_lines = topics.first(4).map { |topic| recall_topic_summary(topic) }
      summary = topic_lines.to_sentence.presence || rolling_summary
      answer = "Here is the conversation context I can pick up from: #{summary}. This is conversation memory, not financial truth; confirmed actuals, balances, and plan amounts still come from approved records. Next CFO move: #{recall_next_move(topics)}"

      Result.new(message: message, direct_answer: answer, follow_up?: true)
    end

    def recall_topic_summary(topic)
      subject = topic["subject"] unless topic["subject"].to_s.casecmp?(topic["title"].to_s)
      scenario_summaries = Array(topic.dig("read_only_plan", "items")).first(3).filter_map do |item|
        recall_scenario_summary(item.to_h)
      end
      participant_context = topic["latest_user_context"] if scenario_summaries.empty?
      assistant_context = if scenario_summaries.empty?
        [ topic["latest_mia_summary"], topic["next_move"] ]
      else
        []
      end

      [
        topic["title"],
        subject,
        topic["amount_label"],
        *scenario_summaries,
        participant_context,
        *assistant_context
      ].compact_blank.uniq.join(" — ")
    end

    def recall_scenario_summary(item)
      label = item["scenario_label"].presence || item["source_text"].presence
      return if label.blank?

      amount = formatted_scenario_amount(item["amount"])
      [ label, amount ].compact_blank.join(" at ")
    end

    def formatted_scenario_amount(value)
      amount = BigDecimal(value.to_s, exception: false)
      return if amount.nil?

      formatted = format("%.2f", amount).sub(/\.00\z/, "").sub(/(\.\d)0\z/, "\\1")
      "$#{formatted}"
    end

    def recall_next_move(topics)
      items = topics.flat_map { |topic| Array(topic.dig("read_only_plan", "items")) }
      if items.any? { |item| purchase_scenario?(item.to_h) }
        return "pick the budget category and funding account that would cover the purchase. Nothing will be saved until you review it."
      end

      return "confirm the timing and which approved category or account would fund the decision." if topics.any? { |topic| topic["amount_label"].present? }

      "tell me which topic you want to continue, or send the missing amount and timing for the active decision."
    end

    def purchase_scenario?(item)
      item["kind"] == "purchase_scenario" ||
        (item["kind"] == "scenario" && item["scenario_type"] == "purchase")
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
        topic["latest_user_context"].present? ? "Prior user context: #{topic['latest_user_context']}" : nil,
        topic["latest_mia_summary"].present? ? "Prior Mia summary: #{topic['latest_mia_summary']}" : nil,
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

    def confirmation?
      message.match?(CONFIRMATION_PATTERN)
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
      self.class.complete_conditional_income_question?(message) ||
        MiaCoachAnswerer.prompt_injection?(active_topic.to_h["latest_user_context"]) ||
        normalized.match?(/\b(?:crypto(?:currency)?|bitcoin|stocks?|take[ -]?home pay|credit card balance)\b/) ||
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
