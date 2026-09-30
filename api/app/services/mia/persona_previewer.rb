# frozen_string_literal: true

require "json"

module Mia
  class PersonaPreviewer
    PREVIEW_CONTEXT = {
      preview_mode: true,
      data_basis: "Fictional no-write Persona Studio preview. No participant or household financial facts are available.",
      metrics: {},
      debts: { records: [] },
      pending_review: []
    }.freeze

    def initialize(persona:, sample_prompt:, responder: nil)
      @persona = persona
      @sample_prompt = sample_prompt.to_s.squish
      @responder = responder
    end

    def call
      return result(status: "not_requested", source: "not_requested", reply: nil, notice: "Enter a test message to run a behavioral preview.") if sample_prompt.blank?

      active_responder = responder || Demo::MiaResponder.new(persona: preview_persona)
      reply = active_responder.call(sample_prompt, context: JSON.generate(PREVIEW_CONTEXT), draft_capable: false)
      source = active_responder.response_source.to_s

      if source.in?(%w[live_model deterministic_safety])
        result(status: "ready", source: source, reply: reply, notice: preview_notice(source))
      else
        result(
          status: "unavailable",
          source: source.presence || "model_unavailable",
          reply: nil,
          notice: "The exact draft compiled successfully, but a behavioral model preview is unavailable right now. No canned reply is being shown as if it answered this test message."
        )
      end
    rescue StandardError => error
      Rails.logger.warn("[Mia::PersonaPreviewer] preview unavailable error=#{error.class}")
      result(
        status: "unavailable",
        source: "preview_error",
        reply: nil,
        notice: "The exact draft compiled successfully, but the behavioral preview could not run. Try again before publishing."
      )
    end

    private

    attr_reader :persona, :sample_prompt, :responder

    def preview_persona
      RuntimePersona.for_preview(
        config: persona.draft_config,
        persona_id: persona.id,
        draft_revision: persona.draft_revision
      )
    end

    def preview_notice(source)
      return "Safety rules took precedence over the coach persona for this test message." if source == "deterministic_safety"

      "Generated from this exact draft in a fictional, no-write preview with no participant financial data."
    end

    def result(status:, source:, reply:, notice:)
      {
        status: status,
        source: source,
        sample_prompt: sample_prompt.presence,
        sample_reply: reply,
        notice: notice
      }
    end
  end
end
