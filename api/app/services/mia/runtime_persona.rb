# frozen_string_literal: true

module Mia
  class RuntimePersona
    FALLBACKS = {
      "low_signal_test" => "Your test came through. Ask me a real money question like “Can I leave my job?” or “Should I pay debt first?” and I’ll use your Household CFO context.",
      "low_signal_greeting" => "I’m ready. Tell me the money decision you want to work through, or choose one of the quick questions. We’ll use your real household numbers and make one clear CFO call at a time.",
      "spending" => "That purse isn’t in the cards right now. If the purchase is not protecting the roof, food, runway, or the dream, it does not get to jump the line today. Put it on a 30-day list, then fund it from true surplus instead of emergency money.",
      "spending_check" => "Pause for one minute. If this purchase is not already funded after bills, debt minimums, groceries, and emergency runway, it waits. Put a dollar amount and a date on it so the want stays dignified without stealing from the household baseline.",
      "crisis" => "I’m really glad you said that out loud. If you might hurt yourself or you feel unsafe, call or text 988 now, call 911, or get next to a trusted person immediately. We can come back to the money plan after you are safe; tonight’s next move is not budgeting, it is getting support.",
      "zero_income_next_step" => "Add your real numbers first so I can coach from the household picture, not a guess.",
      "default_next_step" => "Your next move is one clear choice that protects the household baseline."
    }.freeze
    UNCERTAINTY_LINE = "Based on what I can see, I do not have enough approved data to answer that as a fact yet.".freeze

    attr_reader :version

    def self.for_preview(config:, persona_id:, draft_revision:)
      new(
        nil,
        config: config,
        identifier: "coach_persona_#{persona_id}_draft_#{draft_revision}",
        persona_id: persona_id
      )
    end

    def initialize(version, config: nil, identifier: nil, persona_id: nil)
      @version = version
      @config = PersonaSchema.validate!(config || version.config)
      @identifier = identifier
      @persona_id = persona_id
    end

    def id
      @identifier || "coach_persona_#{persona_id}_version_#{version.version_number}"
    end

    def persona_id
      @persona_id || version.coach_persona_id
    end

    def version_id
      version&.id
    end

    def continuity_id
      "coach_persona_version:#{version_id}"
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
      FALLBACKS.fetch(key.to_s)
    end

    def uncertainty_line
      UNCERTAINTY_LINE
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
  end
end
