# frozen_string_literal: true

require "json"
require "digest"

module Mia
  class PersonaPreviewer
    UNAVAILABLE_NOTICE = "The preview didn't come through. Try again in a minute."
    REJECTED_NOTICE = "The sample answer did not pass the reply checks. Review the response length, format, and safety guidance in Teaching, then preview again."
    PREVIEW_CONTEXT = {
      preview_mode: true,
      data_basis: "No-write Persona Studio preview. Saved participant and household data is not loaded. The coach-authored sample prompt may contain fictional or user-supplied facts.",
      metrics: {},
      debts: { records: [] },
      pending_review: []
    }.freeze

    def self.context_digest
      Digest::SHA256.hexdigest(JSON.generate(PREVIEW_CONTEXT).b)
    end

    def initialize(persona:, sample_prompt:, candidate: nil, responder: nil)
      @persona = persona
      @sample_prompt = sample_prompt.to_s.squish
      @candidate = candidate
      @responder = responder
    end

    def call
      return result(status: "not_requested", source: "not_requested", reply: nil, notice: "Enter a test message to run a behavioral preview.") if sample_prompt.blank?

      active_responder = responder || Demo::MiaResponder.new(
        persona: preview_persona, approved_content: approved_content, strict_privacy: true
      )
      reply = active_responder.call(sample_prompt, context: JSON.generate(PREVIEW_CONTEXT), draft_capable: false)
      source = active_responder.response_source.to_s

      if source == "live_model"
        model_identifier = active_responder.model_identifier.to_s
        provider_request_id = active_responder.provider_request_id.to_s
        unless valid_provider_identifier?(model_identifier) && valid_provider_identifier?(provider_request_id)
          return result(
            status: "unavailable", source: "invalid_provider_provenance", reply: nil,
            notice: UNAVAILABLE_NOTICE
          )
        end

        result(
          status: "ready", source: source, reply: reply, notice: preview_notice(source),
          model_identifier: model_identifier,
          provider_request_id: provider_request_id
        )
      elsif source == "deterministic_safety"
        result(status: "safety_only", source: source, reply: reply, notice: preview_notice(source))
      else
        result(
          status: "unavailable",
          source: source.presence || "model_unavailable",
          reply: nil,
          notice: active_responder.respond_to?(:fallback_reason) && active_responder.fallback_reason == :reply_rejected ? rejection_notice(active_responder) : UNAVAILABLE_NOTICE
        )
      end
    rescue StandardError => error
      Rails.logger.warn("[Mia::PersonaPreviewer] preview unavailable error=#{error.class}")
      result(
        status: "unavailable",
        source: "preview_error",
        reply: nil,
        notice: UNAVAILABLE_NOTICE
      )
    end

    private

    attr_reader :persona, :sample_prompt, :candidate, :responder

    def rejection_notice(active_responder)
      reason = active_responder.rejection_reason if active_responder.respond_to?(:rejection_reason)
      return "The sample answer was outside the response length you chose, even after one rewrite. Adjust the response length in Teaching, then preview again." if reason == :persona_response_shape
      return "The sample answer did not use the response format you chose. Check the format in Teaching, then preview again." if reason == :persona_response_format

      REJECTED_NOTICE
    end

    def preview_persona
      RuntimePersona.for_preview(
        config: candidate ? candidate.config_snapshot : persona.draft_config,
        persona_id: persona.id,
        draft_revision: persona.draft_revision
      )
    end

    def approved_content
      pack_versions = persona.draft_content_pack_links
        .includes(coach_content_pack_version: { entries: { coach_content_item_version: :coach_content_item } })
        .order(:position)
        .map(&:coach_content_pack_version)
      ApprovedContentRetriever.new(persona: preview_persona, query: sample_prompt, pack_versions: pack_versions).call
    end

    def preview_notice(source)
      return "Safety rules took precedence over the coach persona for this test message. This checks the crisis boundary, but it does not exercise the coach persona and cannot authorize publication." if source == "deterministic_safety"

      "Generated from this exact draft in a no-write preview."
    end

    def valid_provider_identifier?(value)
      value.present? && value.length <= 200 && value.match?(/\A[^\s[:cntrl:]]+\z/)
    end

    def result(status:, source:, reply:, notice:, model_identifier: nil, provider_request_id: nil)
      {
        status: status,
        source: source,
        model_identifier: model_identifier,
        provider_request_id: provider_request_id,
        context_digest: self.class.context_digest,
        sample_prompt: sample_prompt.presence,
        sample_reply: reply,
        notice: status == "unavailable" ? notice : "#{notice} Saved participant and household data is not loaded. The coach-authored sample prompt is sent to the configured model when a model preview runs; use fictional details."
      }
    end
  end
end
