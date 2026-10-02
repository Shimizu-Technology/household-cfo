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
      schedule_income_change create_debt update_debt archive_debt restore_debt update_debt_tracking
      create_account update_account archive_account restore_account link_plaid_account reconcile_plaid_account unlink_plaid_account
      create_goal update_goal archive_goal restore_goal
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
      "target_runway_months" => 20
    }.freeze

    def initialize(chat_session, household: nil, persona_context_id: PersonaVersionedContinuity::UNFILTERED_PERSONA_VERSION)
      @chat_session = chat_session
      @household = household || chat_session&.household
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

    attr_reader :chat_session, :household, :persona_context_id

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
      topic = DocumentEvidenceContinuity.sanitize_topic(topic, household: household, require_ready: true)
      return nil if topic.blank? || topic["title"].blank?

      read_only_plan = read_only_plan_payload(topic["read_only_plan"]) if topic["schema_version"].to_i >= 3
      document_evidence = DocumentEvidenceContinuity.payload(topic["document_evidence"], household: household, require_ready: true) if topic["schema_version"].to_i >= 4
      action_plan = action_plan_payload(topic) if topic["schema_version"].to_i >= 5
      schema_version = if document_evidence
        4
      elsif action_plan
        5
      elsif read_only_plan
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
        document_evidence: document_evidence&.deep_symbolize_keys,
        action_plan: action_plan,
        mia_action_draft_id: topic["mia_action_draft_id"].presence,
        transaction_draft_id: topic["transaction_draft_id"].presence,
        updated_at: sanitized_text(topic["updated_at"], max_length: 40)
      }.compact
    end

    def action_plan_payload(topic)
      draft_id = bounded_integer(topic["mia_action_draft_id"], 1..MAX_RECORD_ID)
      return unless draft_id

      draft = household.mia_action_drafts.includes(:mia_action_items).find_by(id: draft_id, draft_type: "action_plan")
      return unless draft

      {
        draft_id: draft.id,
        status: draft.status,
        title: sanitized_text(draft.title, max_length: 160),
        item_count: draft.mia_action_items.length,
        remaining_item_ids: draft.mia_action_items.select { |item| item.applied_at.blank? }.map(&:id).first(12)
      }
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
      return unless value.is_a?(Hash)

      action = value.deep_stringify_keys
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
        schedule_label: sanitized_text(action["schedule_label"], max_length: 80),
        debt_id: bounded_integer(action["debt_id"], 0..MAX_RECORD_ID),
        debt_name: sanitized_text(action["debt_name"], max_length: 120),
        debt_type: sanitized_text(action["debt_type"], max_length: 40),
        balance: sanitized_text(action["balance"], max_length: 40),
        minimum_payment: sanitized_text(action["minimum_payment"], max_length: 40),
        interest_rate_percent: sanitized_text(action["interest_rate_percent"], max_length: 20),
        debt_tracking_mode: sanitized_text(action["debt_tracking_mode"], max_length: 20),
        account_id: bounded_integer(action["account_id"], 0..MAX_RECORD_ID),
        account_name: sanitized_text(action["account_name"], max_length: 120),
        account_type: sanitized_text(action["account_type"], max_length: 40),
        balance_as_of_on: sanitized_text(action["balance_as_of_on"], max_length: 20),
        plaid_account_id: bounded_integer(action["plaid_account_id"], 0..MAX_RECORD_ID),
        reconcile_decision: sanitized_text(action["reconcile_decision"], max_length: 40),
        goal_id: bounded_integer(action["goal_id"], 0..MAX_RECORD_ID),
        goal_name: sanitized_text(action["goal_name"], max_length: 120),
        goal_type: sanitized_text(action["goal_type"], max_length: 40),
        target_amount: sanitized_text(action["target_amount"], max_length: 40),
        current_amount: sanitized_text(action["current_amount"], max_length: 40),
        target_on: sanitized_text(action["target_on"], max_length: 20)
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
          id: bounded_integer(split["id"], 0..MAX_RECORD_ID),
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
