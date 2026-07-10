module HouseholdFinance
  class ConversationContextBuilder
    MAX_SUMMARY_LENGTH = 1_200
    MAX_TOPIC_TEXT_LENGTH = 240
    MAX_TOPICS = 8

    def initialize(chat_session)
      @chat_session = chat_session
    end

    def call
      return empty_context unless chat_session

      {
        context_type: "conversation_continuity",
        memory_rule: "Conversation continuity is context only, not financial truth. Use approved database facts for balances, actuals, plans, transactions, and due dates.",
        rolling_summary: sanitized_text(chat_session.rolling_summary, max_length: MAX_SUMMARY_LENGTH),
        active_topic: topic_payload(chat_session.active_topic),
        open_topics: open_topics.map { |topic| topic_payload(topic) }.compact
      }
    end

    private

    attr_reader :chat_session

    def empty_context
      {
        context_type: "conversation_continuity",
        memory_rule: "Conversation continuity is context only, not financial truth. Use approved database facts for balances, actuals, plans, transactions, and due dates.",
        rolling_summary: nil,
        active_topic: nil,
        open_topics: []
      }
    end

    def open_topics
      Array(chat_session.open_topics).first(MAX_TOPICS)
    end

    def topic_payload(topic)
      topic = topic.to_h.deep_stringify_keys
      return nil if topic.blank? || topic["title"].blank?

      {
        schema_version: topic["schema_version"].presence,
        id: sanitized_text(topic["id"], max_length: 80),
        type: sanitized_text(topic["type"], max_length: 80),
        title: sanitized_text(topic["title"], max_length: MAX_TOPIC_TEXT_LENGTH),
        subject: sanitized_text(topic["subject"], max_length: MAX_TOPIC_TEXT_LENGTH),
        intent: sanitized_text(topic["intent"], max_length: 80),
        confidence: topic["confidence"].presence,
        amount_cents: topic["amount_cents"].presence,
        amount_label: sanitized_text(topic["amount_label"], max_length: 40),
        status: sanitized_text(topic["status"], max_length: 80),
        latest_user_context: sanitized_text(topic["latest_user_context"], max_length: MAX_TOPIC_TEXT_LENGTH),
        latest_mia_summary: sanitized_text(topic["latest_mia_summary"], max_length: MAX_TOPIC_TEXT_LENGTH),
        resolved_message: sanitized_text(topic["resolved_message"], max_length: MAX_TOPIC_TEXT_LENGTH),
        next_move: sanitized_text(topic["next_move"], max_length: MAX_TOPIC_TEXT_LENGTH),
        action: action_payload(topic["action"]),
        mia_action_draft_id: topic["mia_action_draft_id"].presence,
        transaction_draft_id: topic["transaction_draft_id"].presence,
        updated_at: sanitized_text(topic["updated_at"], max_length: 40)
      }.compact
    end

    def action_payload(value)
      action = value.to_h.deep_stringify_keys
      return if action.blank? || action["type"].blank?

      {
        type: sanitized_text(action["type"], max_length: 80),
        category_id: action["category_id"].presence,
        category_name: sanitized_text(action["category_name"], max_length: 80),
        target_category_id: action["target_category_id"].presence,
        target_category_name: sanitized_text(action["target_category_name"], max_length: 80),
        new_name: sanitized_text(action["new_name"], max_length: 80),
        stack_key: sanitized_text(action["stack_key"], max_length: 80),
        amount: sanitized_text(action["amount"], max_length: 40),
        months: Array(action["months"]).map(&:to_i).select { |month| month.between?(1, 12) }.uniq,
        year: action["year"].presence,
        draft_id: action["draft_id"].presence
      }.compact
    end

    def sanitized_text(value, max_length:)
      value.to_s
        .unicode_normalize(:nfkc)
        .gsub(/[[:cntrl:]]/, " ")
        .gsub(/[<>`]/, "")
        .squish
        .truncate(max_length, omission: "…")
        .presence
    end
  end
end
