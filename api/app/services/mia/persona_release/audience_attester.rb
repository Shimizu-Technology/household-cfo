# frozen_string_literal: true

module Mia
  module PersonaRelease
    class AudienceAttester
      class Error < StandardError; end

      def initialize(persona:, actor:)
        @persona = persona
        @actor = actor
      end

      def call!(candidate_digest:, artifact_id:, artifact_fingerprint:, decision:)
        workspace = persona.coach_workspace
        raise Error, "Only a workspace owner or reviewer can review phrase audiences" unless workspace&.allows?(actor, :review)

        persona.with_lock do
          candidate = persona.release_candidates.find_by!(manifest_digest: candidate_digest)
          raise Error, "The release candidate is no longer current" unless candidate.current_for?(persona)
          artifact = Array(candidate.phrase_artifacts_snapshot).find { |entry| entry["artifact_id"].to_s == artifact_id.to_s }
          unless artifact && secure_match?(artifact["fingerprint"], artifact_fingerprint)
            raise Error, "The phrase artifact changed or is not part of this release candidate"
          end
          raise Error, "Choose approve or reject" unless decision.to_s.in?(CoachPhraseAudienceAttestation::DECISIONS)

          existing = candidate.phrase_audience_attestations.find_by(artifact_id: artifact_id)
          return existing if existing&.integrity_valid? && existing.decision == decision.to_s
          raise Error, "This phrase audience was already reviewed" if existing

          self_review = ReviewRules.self_review!(
            workspace: workspace,
            actor: actor,
            self_review: artifact["source_user_id"].to_i == actor.id
          )
          reviewed_at = Time.current
          authority_snapshot, authority_digest = ReviewAuthority.snapshot(workspace: workspace, actor: actor)
          attestation = candidate.phrase_audience_attestations.new(
            artifact_id: artifact.fetch("artifact_id"),
            artifact_fingerprint: artifact.fetch("fingerprint"),
            audience_digest: candidate.audience_digest,
            reviewed_by_user: actor,
            decision: decision,
            self_review: self_review,
            reviewed_at: reviewed_at,
            reviewer_role_snapshot: authority_snapshot.fetch("role"),
            reviewer_authority_snapshot: authority_snapshot,
            reviewer_authority_digest: authority_digest
          )
          attestation.attestation_digest = CoachPhraseAudienceAttestation.digest_for(
            candidate: candidate,
            artifact_id: artifact.fetch("artifact_id"),
            artifact_fingerprint: artifact.fetch("fingerprint"),
            reviewer_id: actor.id,
            decision: decision,
            self_review: self_review,
            reviewed_at: reviewed_at,
            reviewer_authority_snapshot: authority_snapshot,
            reviewer_authority_digest: authority_digest
          )
          attestation.save!
          attestation
        end
      rescue ActiveRecord::RecordNotFound
        raise Error, "Release candidate not found"
      rescue ReviewRules::Error, ActiveRecord::RecordInvalid => error
        raise Error, error.message
      end

      private

      attr_reader :persona, :actor

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
