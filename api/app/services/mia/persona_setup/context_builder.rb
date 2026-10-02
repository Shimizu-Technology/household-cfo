# frozen_string_literal: true

module Mia
  module PersonaSetup
    class ContextBuilder
      MAX_TURNS = 32
      MAX_TRANSCRIPT_CHARACTERS = 16_000

      def initialize(session:, persona:)
        @session = session
        @persona = persona
      end

      def call
        {
          "authoring_state" => safe_authoring_state,
          "allowed_values" => {
            "tone_traits" => PersonaSchema::TONE_TRAITS,
            "energy" => PersonaSchema::ENERGY_STYLES,
            "accountability_style" => PersonaSchema::ACCOUNTABILITY_STYLES,
            "language_style" => PersonaSchema::LANGUAGE_STYLES,
            "phrase_contexts" => PersonaSchema::PHRASE_CONTEXTS,
            "phrase_frequencies" => PersonaSchema::FREQUENCIES
          },
          "recent_turns" => safe_turns
        }
      end

      private

      attr_reader :session, :persona

      def safe_authoring_state
        state = PersonaDraftUpdater.state_for(persona).deep_dup
        state.fetch("draft_config")["phrases"] = Array(state.dig("draft_config", "phrases")).map do |phrase|
          PersonaSchema.normalize(phrase).slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution")
        end
        state
      end

      def safe_turns
        remaining = MAX_TRANSCRIPT_CHARACTERS
        session.turns.where(status: %w[ready failed stale]).order(position: :desc).limit(MAX_TURNS).filter_map do |turn|
          user = turn.user_message.to_s.first([ remaining, 4_000 ].min)
          remaining -= user.length
          assistant = turn.assistant_message.to_s.first([ remaining, 2_000 ].min)
          remaining -= assistant.length
          next if user.blank? && assistant.blank?

          { "user" => user, "assistant" => assistant, "status" => turn.status }
        end.reverse
      end
    end
  end
end
