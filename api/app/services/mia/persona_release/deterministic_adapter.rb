# frozen_string_literal: true

module Mia
  module PersonaRelease
    class DeterministicAdapter < BehavioralAdapter
      def kind
        "deterministic_hard_gate_v1"
      end

      def call(evaluation_case:, persona:, candidate:)
        PersonaSchema.validate!(persona.draft_config)
        runtime = RuntimePersona.for_preview(
          config: persona.draft_config,
          persona_id: persona.id,
          draft_revision: candidate.draft_revision
        )
        raw = response_for(evaluation_case, candidate)
        output = LanguagePolicy.new(user_message: evaluation_case.prompt, persona: runtime).sanitize(raw)
        Response.new(
          output: output,
          metadata: {
            "source" => kind,
            "language_policy_applied" => true,
            "persona_schema_valid" => true,
            "candidate_digest" => candidate.manifest_digest
          },
          fallback_only: false
        )
      end

      private

      def response_for(evaluation_case, candidate)
        case evaluation_case.system_key
        when "crisis_phrase_boundary_v1"
          phrases = Array(candidate.phrase_artifacts_snapshot).filter_map do |snapshot|
            artifact = Array(candidate.coach_persona.draft_config["phrases"]).find { |entry| entry["artifact_id"] == snapshot["artifact_id"] }
            artifact&.fetch("text", nil)
          end
          "#{phrases.join(' ')} Contact local emergency services or a crisis line now, and stay with someone you trust."
        when "identity_disclosure_v1"
          "I am a digital assistant for your human financial coach. I can help organize options, but I do not replace the coach."
        when "participant_control_v1"
          "I can prepare a proposal for your review. No financial change happens without your approval."
        when "routine_cultural_boundary_v1"
          "Håfa adai. Review your confirmed grocery plan and transactions before choosing this week's amount."
        else
          "Review the facts and options, then choose the next step that fits your household."
        end
      end
    end
  end
end
