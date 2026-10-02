# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    class Evidence
      class Error < StandardError; end

      Result = Data.define(:candidate, :run, :approval, :audience_attestations, :digest)

      def initialize(persona:)
        @persona = persona
      end

      def verify_current!(candidate_digest:, run_digest:, approval_digest:)
        candidate = persona.release_candidates.find_by!(manifest_digest: candidate_digest)
        raise Error, "The evaluated release candidate is no longer the current draft" unless candidate.current_for?(persona)

        verify!(candidate: candidate, run_digest: run_digest, approval_digest: approval_digest)
      rescue ActiveRecord::RecordNotFound
        raise Error, "Release evidence was not found"
      end

      def verify!(candidate:, run_digest:, approval_digest:)
        raise Error, "The release candidate evidence is invalid" unless candidate.integrity_valid?
        run = candidate.evaluation_runs.find_by!(run_digest: run_digest)
        latest_run = candidate.evaluation_runs.order(id: :desc).first
        raise Error, "A newer evaluation run exists for this release candidate" unless latest_run&.id == run.id
        raise Error, "The evaluation run is not a current intact pass" unless run.current_suite_pass?
        approval = run.approval
        unless approval&.decision == "approved" && approval.integrity_valid? && secure_match?(approval.approval_digest, approval_digest)
          raise Error, "The exact passed evaluation requires approval"
        end

        attestations = candidate.phrase_audience_attestations.order(:artifact_id).to_a
        required = Array(candidate.phrase_artifacts_snapshot)
        approved_ids = attestations.filter_map do |attestation|
          attestation.artifact_id.to_s if attestation.decision == "approved" && attestation.integrity_valid?
        end
        missing = required.map { |artifact| artifact.fetch("artifact_id").to_s } - approved_ids
        raise Error, "Every phrase requires an approval for this exact audience and culture" if missing.any?

        digest = self.class.digest_for(candidate: candidate, run: run, approval: approval, attestations: attestations)
        Result.new(candidate: candidate, run: run, approval: approval, audience_attestations: attestations, digest: digest)
      end

      def self.digest_for(candidate:, run:, approval:, attestations:)
        Digest::SHA256.hexdigest(JSON.generate(PhraseManifest.canonicalize({
          schema: "persona_release_evidence_v2",
          candidate_digest: candidate.manifest_digest,
          audience_digest: candidate.audience_digest,
          run_digest: run.run_digest,
          approval_digest: approval.approval_digest,
          phrase_audience_attestation_digests: attestations.sort_by { |item| item.artifact_id.to_s }.map(&:attestation_digest)
        })).b)
      end

      private

      attr_reader :persona

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
