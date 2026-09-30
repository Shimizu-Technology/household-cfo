# frozen_string_literal: true

module Mia
  class Capabilities
    PERSONA_CONFIGURATION_PATTERN = /\b(?:switch|change|use|set|configure|edit|save|remember)\b.{0,140}\b(?:persona|personality|voice|tone|accent|dialect|regional style|speaking style|writing style)\b|\b(?:persona|personality|voice|tone|accent|dialect|regional style|speaking style|writing style)\b.{0,140}\b(?:switch|change|use|set|configure|edit|save|remember)\b|\b(?:talk|sound|speak|write)\s+like\b|\b(?:talk|sound|speak|write)\b.{0,80}\b(?:someone|a person)\s+from\b|\b(?:remember|save|store|persist)\b.{0,140}\b(?:prefer|preference|check-?ins?|persona|personality|voice|tone|accent|dialect|speaking style|writing style|for future|next time|going forward)\b/i.freeze

    CURRENT = {
      persona_switch: false,
      persona_persistence: false,
      long_term_conversation_memory: false,
      coach_persona_editor: true
    }.freeze

    def self.persona_configuration_request?(message)
      message.to_s.squish.match?(PERSONA_CONFIGURATION_PATTERN)
    end

    def self.persona_configuration_answer
      "Your coach’s published assistant persona is assigned through your cohort, so it cannot be switched or edited from participant chat. Coaches and admins can build, preview, publish, and assign a structured persona in Coach Studio. I did not save a new voice, regional style, or memory, and no financial numbers changed."
    end
  end
end
