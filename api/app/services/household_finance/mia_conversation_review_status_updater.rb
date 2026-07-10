module HouseholdFinance
  class MiaConversationReviewStatusUpdater
    REFERENCE_KEYS = %w[mia_action_draft_id transaction_draft_id].freeze

    def initialize(chat_session, reference_key:, reference_id:, status:, summary:)
      @chat_session = chat_session
      @reference_key = reference_key.to_s
      @reference_id = reference_id.to_i
      @status = status.to_s
      @summary = summary.to_s.squish.truncate(240, omission: "…")
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
      lines = topics.first(6).map do |topic|
        [ topic["title"], topic["subject"], topic["status"], topic["latest_mia_summary"] ].compact_blank.join(" — ")
      end
      return if lines.empty?

      "Open conversation threads: #{lines.join(' | ')}".truncate(1_500, omission: "…")
    end
  end
end
