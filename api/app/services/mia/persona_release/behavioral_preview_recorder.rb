# frozen_string_literal: true

module Mia
  module PersonaRelease
    class BehavioralPreviewRecorder
      class Error < StandardError; end

      def initialize(persona:, actor:)
        @persona = persona
        @actor = actor
      end

      def call!(candidate:, preview:)
        unless preview.fetch(:status) == "ready" && preview.fetch(:source) == "live_model"
          raise Error, "Only a live model preview can authorize publication"
        end
        unless valid_provider_identifier?(preview[:model_identifier]) && valid_provider_identifier?(preview[:provider_request_id])
          raise Error, "A concrete model identifier and provider request ID are required for publication evidence"
        end
        persona.with_lock do
          raise Error, "The release candidate changed during the behavioral preview" unless candidate.current_for?(persona)
          unless preview.fetch(:context_digest) == PersonaPreviewer.context_digest
            raise Error, "The behavioral preview used an unexpected data context"
          end

          record = candidate.behavioral_preview_evidences.new(
            generated_by_user: actor, prompt: preview.fetch(:sample_prompt), output: preview.fetch(:sample_reply),
            response_source: preview.fetch(:source), model_identifier: preview.fetch(:model_identifier),
            provider_request_id: preview[:provider_request_id],
            privacy_scope: CoachPersonaBehavioralPreviewEvidence::PRIVACY_SCOPE,
            context_digest: preview.fetch(:context_digest), candidate_digest: candidate.manifest_digest,
            config_digest: candidate.config_digest, content_manifest_digest: candidate.content_manifest_digest,
            phrase_manifest_digest: candidate.phrase_manifest_digest, generated_at: Time.current
          )
          record.evidence_digest = CoachPersonaBehavioralPreviewEvidence.digest_for(record)
          record.save!
          record
        end
      rescue KeyError, ActiveRecord::RecordInvalid => error
        raise Error, error.message
      end

      private

      attr_reader :persona, :actor

      def valid_provider_identifier?(value)
        normalized = value.to_s
        normalized.present? && normalized.length <= 200 && normalized.match?(/\A[^\s[:cntrl:]]+\z/)
      end
    end
  end
end
