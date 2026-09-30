# frozen_string_literal: true

module Mia
  class AssistantMessageWriter
    def initialize(session:, persona:)
      @session = session
      @persona = persona
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
        coach_persona_version_id: persona_version_id
      )
    end

    private

    attr_reader :session, :persona

    def persona_version_id
      persona.version_id if persona.respond_to?(:version_id)
    end
  end
end
