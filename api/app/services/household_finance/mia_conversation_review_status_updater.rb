module HouseholdFinance
  class MiaConversationReviewStatusUpdater
    REFERENCE_KEYS = %w[mia_action_draft_id transaction_draft_id].freeze

    def initialize(chat_session, reference_key:, reference_id:, status:, summary:)
      @chat_session = chat_session
      @reference_key = reference_key.to_s
      @reference_id = reference_id.to_i
      @status = sanitized_text(status, max_length: 80).to_s
      @summary = sanitized_text(summary, max_length: 240).to_s
    end

    def call
      return false unless chat_session
      return false unless reference_key.in?(REFERENCE_KEYS) && reference_id.positive?

      chat_session.with_lock do
        active_topic = updated_topic(chat_session.active_topic)
        open_topics = Array(chat_session.open_topics).map { |topic| updated_topic(topic) }
        chat_session.update!(
          active_topic: active_topic,
          open_topics: open_topics,
          rolling_summary: build_summary(open_topics)
        )
      end
      true
    end

    private

    attr_reader :chat_session, :reference_key, :reference_id, :status, :summary

    def updated_topic(value)
      topic = value.to_h.deep_stringify_keys
      return topic unless topic[reference_key].to_i == reference_id

      topic.merge(
        "status" => status,
        "latest_mia_summary" => summary,
        "updated_at" => Time.current.iso8601
      )
    end

    def build_summary(topics)
      lines = topics.first(6).filter_map do |topic|
        values = [ topic["title"], topic["subject"], topic["status"], topic["latest_mia_summary"] ]
          .filter_map { |value| sanitized_text(value, max_length: 240) }
        values.join(" — ").presence
      end
      return if lines.empty?

      sanitized_text("Open conversation threads: #{lines.join(' | ')}", max_length: 1_500)
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
