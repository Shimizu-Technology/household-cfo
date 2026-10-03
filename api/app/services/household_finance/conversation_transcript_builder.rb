module HouseholdFinance
  class ConversationTranscriptBuilder
    UNFILTERED_PERSONA_VERSION = Object.new.freeze
    UNFILTERED_COHORT = Object.new.freeze
    UNFILTERED_COHORT_RELEASE = Object.new.freeze
    MAX_MESSAGES = 32
    FETCH_LIMIT = 80
    MAX_TOTAL_CHARACTERS = 24_000
    MAX_MESSAGE_CHARACTERS = ChatMessage::MAX_CONTENT_LENGTH

    def initialize(chat_session, persona_version_id: UNFILTERED_PERSONA_VERSION, cohort_id: UNFILTERED_COHORT,
      cohort_release_id: UNFILTERED_COHORT_RELEASE)
      @chat_session = chat_session
      @persona_version_id = persona_version_id
      @cohort_id = cohort_id
      @cohort_release_id = cohort_release_id
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
        break if used_characters + next_size > MAX_TOTAL_CHARACTERS

        selected << payload
        used_characters += next_size
        break if selected.length >= MAX_MESSAGES
      end

      selected.reverse
    end

    private

    attr_reader :chat_session, :persona_version_id, :cohort_id, :cohort_release_id

    def message_payload(message)
      return unless message.role.in?(%w[user assistant])
      return if message_from_other_cohort?(message)
      return if message_from_other_cohort_release?(message)
      return if assistant_from_other_persona_version?(message)

      content = message.content.to_s.squish.truncate(MAX_MESSAGE_CHARACTERS, omission: "…")
      return if content.blank?

      {
        id: message.id,
        role: message.role,
        content: content,
        coach_persona_version_id: message.coach_persona_version_id,
        created_at: message.created_at&.iso8601
      }
    end

    def message_from_other_cohort?(message)
      return false if cohort_id.equal?(UNFILTERED_COHORT)

      message.cohort_id != cohort_id
    end

    def message_from_other_cohort_release?(message)
      return false if cohort_release_id.equal?(UNFILTERED_COHORT_RELEASE)

      message.cohort_release_id != cohort_release_id
    end

    def assistant_from_other_persona_version?(message)
      return false unless message.role == "assistant"
      return false if persona_version_id.equal?(UNFILTERED_PERSONA_VERSION)

      message.coach_persona_version_id != persona_version_id
    end
  end
end
