module HouseholdFinance
  class ConversationContextBuilder
    MAX_SUMMARY_LENGTH = 1_200
    MAX_TOPIC_TEXT_LENGTH = 240
    MAX_TOPICS = 8
    MAX_READ_ONLY_PLAN_ITEMS = 6

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

      read_only_plan = read_only_plan_payload(topic["read_only_plan"]) if topic["schema_version"].to_i >= 3
      schema_version = if read_only_plan
        3
      elsif topic["schema_version"].to_i >= 2
        2
      end

      {
        schema_version: schema_version,
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
        read_only_plan: read_only_plan,
        mia_action_draft_id: topic["mia_action_draft_id"].presence,
        transaction_draft_id: topic["transaction_draft_id"].presence,
        updated_at: sanitized_text(topic["updated_at"], max_length: 40)
      }.compact
    end

    def read_only_plan_payload(value)
      plan = value.to_h.deep_stringify_keys
      items = Array(plan["items"]).first(MAX_READ_ONLY_PLAN_ITEMS).filter_map do |raw_item|
        item = raw_item.to_h.deep_stringify_keys
        kind = sanitized_text(item["kind"], max_length: 40)
        source_text = sanitized_text(item["source_text"], max_length: 500)
        resolved_question = sanitized_text(item["resolved_question"], max_length: 600)
        next if kind.blank? || source_text.blank? || resolved_question.blank?

        {
          kind: kind,
          source_text: source_text,
          resolved_question: resolved_question,
          basis: sanitized_text(item["basis"], max_length: 20),
          scenario_type: sanitized_text(item["scenario_type"], max_length: 40),
          scenario_label: sanitized_text(item["scenario_label"], max_length: 120),
          amount: sanitized_text(item["amount"], max_length: 40),
          effective_on: sanitized_text(item["effective_on"], max_length: 20),
          timing_unavailable: ActiveModel::Type::Boolean.new.cast(item["timing_unavailable"])
        }.compact
      end
      return if items.empty?

      {
        title: sanitized_text(plan["title"], max_length: 160) || "Household CFO questions",
        items: items
      }
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
