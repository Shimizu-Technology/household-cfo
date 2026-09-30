# frozen_string_literal: true

module Mia
  class RuntimePersona
    attr_reader :version

    def initialize(version)
      @version = version
      @config = PersonaSchema.validate!(version.config)
    end

    def id
      "coach_persona_#{persona_id}_version_#{version.version_number}"
    end

    def persona_id
      version.coach_persona_id
    end

    def version_id
      version.id
    end

    def name
      identity.fetch("assistant_name")
    end

    def role
      identity.fetch("assistant_relationship")
    end

    def voice_summary
      [ voice.fetch("tone_traits").to_sentence, voice.fetch("energy") ].compact_blank.join(". ")
    end

    def disclaimer
      "#{name} is an AI coaching assistant built from #{identity.fetch('human_coach_name')}'s approved guidance. " \
        "#{name} does not impersonate or replace that coach and does not replace legal, tax, investment, accounting, therapeutic, or financial advice."
    end

    def system_prompt
      PersonaPromptBuilder.call(config)
    end

    def fallback_response(key)
      legacy_fallback.fallback_response(key)
    end

    def uncertainty_line
      legacy_fallback.uncertainty_line
    end

    def cultural_phrases
      config.fetch("phrases")
    end

    def response_shape
      config.fetch("response_shape")
    end

    private

    attr_reader :config

    def identity
      config.fetch("identity")
    end

    def voice
      config.fetch("voice")
    end

    def legacy_fallback
      @legacy_fallback ||= Persona.default
    end
  end
end
