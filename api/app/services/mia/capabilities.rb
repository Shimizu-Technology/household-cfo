# frozen_string_literal: true

module Mia
  class Capabilities
    PERSONA_CONFIGURATION_PATTERN = /\b(?:switch|change|use|set|configure|edit|save|remember)\b.{0,140}\b(?:persona|voice|tone|accent|dialect|regional style|speaking style|writing style)\b|\b(?:persona|voice|tone|accent|dialect|regional style|speaking style|writing style)\b.{0,140}\b(?:switch|change|use|set|configure|edit|save|remember)\b|\b(?:talk|sound|speak|write)\s+like\b|\b(?:talk|sound|speak|write)\b.{0,80}\b(?:someone|a person)\s+from\b|\b(?:remember|save|store|persist)\b.{0,140}\b(?:prefer|preference|check-?ins?|persona|voice|tone|accent|dialect|speaking style|writing style|for future|next time|going forward)\b/i.freeze

    CURRENT = {
      persona_switch: false,
      persona_persistence: false,
      long_term_conversation_memory: false,
      coach_persona_editor: false
    }.freeze

    def self.persona_configuration_request?(message)
      message.to_s.squish.match?(PERSONA_CONFIGURATION_PATTERN)
    end

    def self.persona_configuration_answer
      "Coach voice switching and saved style preferences are not available in this pilot yet. Mia currently uses the global pilot Household CFO persona, and I did not save a new voice, regional style, or memory. No financial numbers changed. A future coach-persona editor will need coach-approved sources, preview, testing, and an explicit publish step before a participant can use it."
    end
  end
end
