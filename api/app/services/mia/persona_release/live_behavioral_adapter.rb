# frozen_string_literal: true

require "json"

module Mia
  module PersonaRelease
    class LiveBehavioralAdapter < BehavioralAdapter
      MAX_OUTPUT_CHARS = 4_000
      EVALUATION_CONTEXT = {
        evaluation_mode: true,
        data_basis: "No-write persona release evaluation. No participant, household, account, transaction, chat, or memory data is loaded.",
        metrics: {}, debts: { records: [] }, pending_review: []
      }.freeze

      def initialize(responder_factory: nil)
        @responder_factory = responder_factory
      end

      def kind
        "live_candidate_behavior_v1"
      end

      def call(evaluation_case:, persona:, candidate:)
        return unavailable(candidate, "candidate_stale") unless candidate.current_for?(persona)

        runtime = RuntimePersona.for_preview(config: candidate.config_snapshot, persona_id: persona.id, draft_revision: candidate.draft_revision)
        responder = build_responder(runtime, persona, evaluation_case.prompt)
        output = responder.call(
          evaluation_case.prompt,
          context: JSON.generate(EVALUATION_CONTEXT.merge(candidate_digest: candidate.manifest_digest)),
          draft_capable: false
        ).to_s.squish
        source = responder.response_source.to_s
        return unavailable(candidate, source.presence || "model_unavailable") unless source == "live_model"
        return unavailable(candidate, "invalid_model_output") if output.blank? || output.length > MAX_OUTPUT_CHARS

        Response.new(output: output, metadata: metadata(candidate, source).merge("output_chars" => output.length), fallback_only: false)
      rescue StandardError => error
        Rails.logger.warn("[Mia::PersonaRelease::LiveBehavioralAdapter] unavailable error=#{error.class}")
        unavailable(candidate, "model_error")
      end

      private

      attr_reader :responder_factory

      def build_responder(runtime, persona, prompt)
        return responder_factory.call(runtime) if responder_factory

        approved_content = ApprovedContentRetriever.new(
          persona: runtime, query: prompt, pack_versions: persona.draft_content_pack_versions_ordered
        ).call
        Demo::MiaResponder.new(persona: runtime, approved_content: approved_content, strict_privacy: true)
      end

      def unavailable(candidate, source)
        Response.new(output: "", metadata: metadata(candidate, source), fallback_only: true)
      end

      def metadata(candidate, source)
        {
          "source" => source,
          "adapter" => kind,
          "candidate_digest" => candidate.manifest_digest,
          "privacy_mode" => "no_participant_or_household_data",
          "max_output_chars" => MAX_OUTPUT_CHARS
        }
      end
    end
  end
end
