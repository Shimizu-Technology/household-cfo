module HouseholdFinance
  class ConversationTranscriptBuilder
    MAX_MESSAGES = 32
    FETCH_LIMIT = 80
    MAX_TOTAL_CHARACTERS = 24_000
    MAX_MESSAGE_CHARACTERS = 4_000
    MIN_RECENT_MESSAGES = 8

    def initialize(chat_session)
      @chat_session = chat_session
    end

    def call
      return [] unless chat_session

      candidates = chat_session.chat_messages.order(created_at: :desc, id: :desc).limit(FETCH_LIMIT).to_a.reverse
      selected = []
      used_characters = 0

      candidates.reverse_each do |message|
        payload = message_payload(message)
        next unless payload

        next_size = payload.fetch(:content).length
        break if selected.length >= MIN_RECENT_MESSAGES && used_characters + next_size > MAX_TOTAL_CHARACTERS

        selected << payload
        used_characters += next_size
        break if selected.length >= MAX_MESSAGES
      end

      selected.reverse
    end

    private

    attr_reader :chat_session

    def message_payload(message)
      return unless message.role.in?(%w[user assistant])

      content = message.content.to_s.squish.truncate(MAX_MESSAGE_CHARACTERS, omission: "…")
      return if content.blank?

      { id: message.id, role: message.role, content: content, created_at: message.created_at&.iso8601 }
    end
  end
end
