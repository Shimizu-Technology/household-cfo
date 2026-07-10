require "securerandom"

module HouseholdFinance
  class MiaConversationStateUpdater
    MAX_TOPICS = 8
    MAX_TEXT_LENGTH = 240

    def initialize(chat_session, intent_result:, user_message:, assistant_message:, mia_action_draft: nil, transaction_draft: nil)
      @chat_session = chat_session
      @intent_result = intent_result
      @user_message = user_message
      @assistant_message = assistant_message
      @mia_action_draft = mia_action_draft
      @transaction_draft = transaction_draft
    end

    def call
      return false unless chat_session && intent_result && user_message && assistant_message

      chat_session.with_lock do
        current = normalized_topic(chat_session.active_topic)
        topic = topic_for(current)
        topics = normalized_topics(chat_session.open_topics)
        topics = upsert_topic(topics, topic) if topic

        active_topic = topic.presence || (intent_result.continuation ? current.presence : nil) || {}
        chat_session.update!(
          active_topic: active_topic,
          open_topics: topics,
          rolling_summary: build_summary(topics),
          last_compacted_message_id: assistant_message.id,
          last_compacted_at: Time.current
        )
      end
      true
    rescue StandardError => e
      Rails.logger.warn("Mia conversation state update failed chat_session_id=#{chat_session&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :chat_session, :intent_result, :user_message, :assistant_message, :mia_action_draft, :transaction_draft

    def topic_for(current)
      return recall_topic(current) if intent_result.intent == "recall"

      topic = intent_result.topic.to_h.deep_symbolize_keys
      return current if topic[:title].blank? && intent_result.continuation
      return nil if topic[:title].blank?

      action = intent_result.action.to_h.deep_symbolize_keys
      {
        "schema_version" => 2,
        "id" => continuation_topic_id(current, topic),
        "type" => topic[:type].presence || intent_result.intent,
        "title" => bounded(topic[:title], 160),
        "subject" => bounded(topic[:subject], 160),
        "status" => topic_status,
        "latest_user_context" => bounded(user_message.content, MAX_TEXT_LENGTH),
        "latest_mia_summary" => bounded(assistant_message.content, MAX_TEXT_LENGTH),
        "resolved_message" => bounded(intent_result.resolved_message, MAX_TEXT_LENGTH),
        "intent" => intent_result.intent,
        "confidence" => intent_result.confidence.to_f.round(3),
        "action" => action[:type].to_s == "none" ? nil : action,
        "mia_action_draft_id" => mia_action_draft&.id,
        "transaction_draft_id" => transaction_draft&.id,
        "updated_at" => Time.current.iso8601
      }.compact
    end

    def recall_topic(current)
      candidates = normalized_topics(chat_session.open_topics)
      resolved = intent_result.topic.to_h.deep_symbolize_keys
      if resolved[:type].present? || resolved[:subject].present?
        matched = candidates.find do |topic|
          type_matches = resolved[:type].blank? || topic["type"].to_s == resolved[:type].to_s
          subject_matches = resolved[:subject].blank? || topic["subject"].to_s.casecmp?(resolved[:subject].to_s)
          type_matches && subject_matches
        end
        return matched if matched
      end

      candidates.first || current
    end

    def continuation_topic_id(current, topic)
      return current["id"] if intent_result.continuation && current.present?
      return current["id"] if current.present? && current["type"].to_s == topic[:type].to_s && current["subject"].to_s.casecmp?(topic[:subject].to_s)

      SecureRandom.uuid
    end

    def topic_status
      return "pending_review" if mia_action_draft || transaction_draft
      return "needs_clarification" if intent_result.clarification?

      "open"
    end

    def upsert_topic(topics, topic)
      existing_index = topics.index do |candidate|
        candidate["id"] == topic["id"] ||
          (candidate["type"].to_s == topic["type"].to_s && candidate["subject"].to_s.casecmp?(topic["subject"].to_s))
      end
      topics.delete_at(existing_index) if existing_index
      [ topic, *topics ].first(MAX_TOPICS)
    end

    def build_summary(topics)
      return nil if topics.empty?

      lines = topics.first(6).map do |topic|
        [ topic["title"], topic["subject"], topic["status"], topic["latest_mia_summary"] ].compact_blank.join(" — ")
      end
      bounded("Open conversation threads: #{lines.join(' | ')}", 1_500)
    end

    def normalized_topics(value)
      Array(value).filter_map { |topic| normalized_topic(topic) }.first(MAX_TOPICS)
    end

    def normalized_topic(value)
      topic = value.to_h.deep_stringify_keys
      return nil if topic.blank? || topic["title"].blank?

      topic
    end

    def bounded(value, limit)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(limit, omission: "…").presence
    end
  end
end
