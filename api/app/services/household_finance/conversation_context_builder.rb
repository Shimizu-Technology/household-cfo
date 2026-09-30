module HouseholdFinance
  class ConversationContextBuilder
    MAX_SUMMARY_LENGTH = 1_200
    MAX_TOPIC_TEXT_LENGTH = 240
    MAX_TOPICS = 8
    MAX_READ_ONLY_PLAN_ITEMS = 6
    MAX_ACTION_SPLITS = 20
    MAX_RECORD_ID = 9_223_372_036_854_775_807
    ACTION_TYPES = %w[
      none set_allocation increase_allocation decrease_allocation move_allocation create_category
      rename_category reclassify_category archive_category restore_category review_pending_action
      create_transaction_draft update_transaction_draft ignore_transaction_drafts update_household_setup
      schedule_income_change
    ].freeze
    SETUP_UPDATE_LIMITS = {
      "household_name" => 120,
      "primary_goal" => 500,
      "primary_income" => 40,
      "business_income" => 40,
      "fixed_expenses" => 40,
      "flexible_spend" => 40,
      "expected_sinking_fund" => 40,
      "unexpected_sinking_fund" => 40,
      "emergency_fund" => 40,
      "other_assets" => 40,
      "credit_card_debt" => 40,
      "debt_payment" => 40,
      "target_runway_months" => 20
    }.freeze

    def initialize(chat_session, persona_context_id: PersonaVersionedContinuity::UNFILTERED_PERSONA_VERSION)
      @chat_session = chat_session
      @persona_context_id = persona_context_id
    end

    def call
      return empty_context unless chat_session

      active_topic = topic_payload(chat_session.active_topic)
      open_topics = self.open_topics.map { |topic| topic_payload(topic) }.compact

      {
        context_type: "conversation_continuity",
        memory_rule: "Conversation continuity is context only, not financial truth. Use approved database facts for balances, actuals, plans, transactions, and due dates.",
        rolling_summary: rolling_summary(active_topic, open_topics),
        active_topic: active_topic,
        open_topics: open_topics
      }
    end

    private

    attr_reader :chat_session, :persona_context_id

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
      topic = PersonaVersionedContinuity.filter_topic(topic, persona_context_id: persona_context_id)
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

    def rolling_summary(active_topic, open_topics)
      unless PersonaVersionedContinuity.filtering?(persona_context_id)
        return sanitized_text(chat_session.rolling_summary, max_length: MAX_SUMMARY_LENGTH)
      end

      topics = [ active_topic, *open_topics ].compact.uniq { |topic| topic[:id].presence || topic.slice(:type, :subject) }
      lines = topics.first(6).filter_map do |topic|
        [
          topic[:title],
          topic[:subject],
          topic[:amount_label],
          topic[:status],
          topic[:latest_mia_summary],
          topic[:next_move]
        ].compact_blank.join(" — ").presence
      end
      return if lines.empty?

      sanitized_text("Open conversation topics: #{lines.join(' | ')}", max_length: MAX_SUMMARY_LENGTH)
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
      type = sanitized_text(action["type"], max_length: 80)
      return if action.blank? || !type.in?(ACTION_TYPES)

      {
        type: type,
        category_id: bounded_integer(action["category_id"], 0..MAX_RECORD_ID),
        category_name: sanitized_text(action["category_name"], max_length: 80),
        target_category_id: bounded_integer(action["target_category_id"], 0..MAX_RECORD_ID),
        target_category_name: sanitized_text(action["target_category_name"], max_length: 80),
        new_name: sanitized_text(action["new_name"], max_length: 80),
        stack_key: sanitized_text(action["stack_key"], max_length: 80),
        amount: sanitized_text(action["amount"], max_length: 40),
        months: action_months(action),
        year: bounded_integer(action["year"], 0..2100),
        draft_id: bounded_integer(action["draft_id"], 0..MAX_RECORD_ID),
        occurred_on: sanitized_text(action["occurred_on"], max_length: 20),
        merchant: sanitized_text(action["merchant"], max_length: 120),
        all_pending: strict_boolean(action["all_pending"]),
        splits: action_splits(action["splits"]),
        setup_updates: setup_updates_payload(action["setup_updates"]),
        income_source_id: bounded_integer(action["income_source_id"], 0..MAX_RECORD_ID),
        income_source_name: sanitized_text(action["income_source_name"], max_length: 120),
        entry_type: sanitized_text(action["entry_type"], max_length: 40),
        effective_on: sanitized_text(action["effective_on"], max_length: 20),
        schedule_label: sanitized_text(action["schedule_label"], max_length: 80)
      }.compact
    end

    def action_months(action)
      return unless action.key?("months")

      Array(action["months"])
        .filter_map { |month| bounded_integer(month, 1..12) }
        .uniq
        .sort
    end

    def action_splits(value)
      return unless value.is_a?(Array)

      value.first(MAX_ACTION_SPLITS).filter_map do |raw_split|
        next unless raw_split.is_a?(Hash)

        split = raw_split.deep_stringify_keys
        payload = {
          category_id: bounded_integer(split["category_id"], 0..MAX_RECORD_ID),
          category_name: sanitized_text(split["category_name"], max_length: 80),
          amount: sanitized_text(split["amount"], max_length: 40)
        }.compact
        payload if payload.present?
      end
    end

    def setup_updates_payload(value)
      return unless value.is_a?(Hash)

      updates = value.deep_stringify_keys
      SETUP_UPDATE_LIMITS.each_with_object({}) do |(key, max_length), payload|
        next unless updates.key?(key)

        sanitized = sanitized_text(updates[key], max_length: max_length)
        payload[key.to_sym] = sanitized if sanitized
      end.presence
    end

    def bounded_integer(value, range)
      integer = Integer(value, exception: false)
      integer if integer&.in?(range)
    end

    def strict_boolean(value)
      value if value == true || value == false
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
