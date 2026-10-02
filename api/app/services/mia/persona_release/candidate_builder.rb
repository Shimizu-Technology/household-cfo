# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    class CandidateBuilder
      class Error < StandardError; end

      class << self
        def snapshot(persona)
          PersonaSchema.validate!(persona.draft_config)
          phrases = Array(persona.draft_config["phrases"]).map do |artifact|
            normalized = PersonaSchema.normalize(artifact)
            {
              "artifact_id" => normalized.fetch("artifact_id"),
              "fingerprint" => normalized.fetch("fingerprint"),
              "provenance" => normalized.fetch("provenance"),
              "source_user_id" => normalized.fetch("source_user_id"),
              "source_role_at_capture" => normalized.fetch("source_role_at_capture")
            }
          end
          audience = audience_snapshot(persona.draft_config)
          audience_digest = digest(audience)
          manifest = {
            "schema" => "persona_release_candidate_v2",
            "persona_id" => persona.id,
            "draft_revision" => persona.draft_revision,
            "config_digest" => PersonaSchema.digest(persona.draft_config),
            "content_manifest_digest" => persona.draft_content_manifest_digest,
            "phrase_manifest_digest" => persona.draft_phrase_manifest_digest,
            "audience_digest" => audience_digest,
            "phrase_artifacts" => phrases
          }
          {
            config_digest: manifest.fetch("config_digest"),
            content_manifest_digest: manifest.fetch("content_manifest_digest"),
            phrase_manifest_digest: manifest.fetch("phrase_manifest_digest"),
            audience_digest: audience_digest,
            audience_snapshot: audience,
            phrase_artifacts_snapshot: phrases,
            manifest: manifest,
            manifest_digest: CoachPersonaReleaseCandidate.digest_for(manifest)
          }
        rescue KeyError, PersonaSchema::InvalidConfiguration, ArgumentError
          raise Error, "The exact persona draft cannot be sealed as a release candidate"
        end

        private

        def audience_snapshot(config)
          normalized = PersonaSchema.normalize(config)
          {
            "schema" => "persona_audience_v1",
            "audience" => normalized.dig("identity", "audience"),
            "client_term" => normalized.dig("identity", "client_term"),
            "culture" => normalized.fetch("culture")
          }
        end

        def digest(value)
          Digest::SHA256.hexdigest(JSON.generate(PhraseManifest.canonicalize(value)).b)
        end
      end

      def initialize(persona:, actor:)
        @persona = persona
        @actor = actor
      end

      def call!
        authorize!
        persona.with_lock do
          raise Error, "Archived personas cannot be evaluated" if persona.archived?

          attributes = self.class.snapshot(persona)
          existing = persona.release_candidates.find_by(manifest_digest: attributes.fetch(:manifest_digest))
          return existing if existing&.integrity_valid?

          persona.release_candidates.create!(
            attributes.merge(
              created_by_user: actor,
              draft_revision: persona.draft_revision,
              sealed_at: Time.current
            )
          )
        end
      rescue ActiveRecord::RecordNotUnique
        persona.release_candidates.find_by!(manifest_digest: self.class.snapshot(persona).fetch(:manifest_digest))
      end

      private

      attr_reader :persona, :actor

      def authorize!
        raise Error, "Only a workspace editor can prepare a release candidate" unless persona.coach_workspace&.allows?(actor, :edit)
      end
    end
  end
end
