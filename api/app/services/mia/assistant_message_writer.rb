# frozen_string_literal: true

module Mia
  class AssistantMessageWriter
    def initialize(session:, persona:, participant_runtime: nil)
      @session = session
      @persona = persona
      @participant_runtime = participant_runtime
    end

    def create!(content:, presentation: {})
      build(content: content, presentation: presentation).tap(&:save!)
    end

    def build(content:, presentation: {})
      session.chat_messages.build(
        role: "assistant",
        content: content,
        presentation: presentation,
        assistant_author: persona.name,
        coach_persona_version_id: persona_version_id,
        cohort_id: participant_runtime&.cohort_id,
        cohort_release_id: participant_runtime&.release_id
      )
    end

    private

    attr_reader :session, :persona, :participant_runtime

    def persona_version_id
      persona.version_id if persona.respond_to?(:version_id)
    end
  end
end
