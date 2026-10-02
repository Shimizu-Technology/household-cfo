# frozen_string_literal: true

module Mia
  module PersonaRelease
    class Readiness
      def initialize(persona:)
        @persona = persona
      end

      def call
        candidate = current_candidate
        return empty_readiness unless candidate

        run = candidate.evaluation_runs.order(created_at: :desc).first
        approval = run&.approval
        attestations = candidate.phrase_audience_attestations.index_by { |item| item.artifact_id.to_s }
        phrase_reviews = Array(candidate.phrase_artifacts_snapshot).map do |artifact|
          attestation = attestations[artifact.fetch("artifact_id").to_s]
          {
            artifact_id: artifact.fetch("artifact_id"),
            artifact_fingerprint: artifact.fetch("fingerprint"),
            decision: attestation&.decision,
            reviewed: attestation&.integrity_valid? == true,
            self_review: attestation&.self_review? == true
          }
        end
        ready = run&.current_suite_pass? == true && approval&.decision == "approved" && approval.integrity_valid? &&
          phrase_reviews.all? { |review| review.fetch(:reviewed) && review.fetch(:decision) == "approved" }
        {
          gate_version: "gate_v2",
          ready: ready,
          candidate: serialize_candidate(candidate),
          evaluation_run: serialize_run(run),
          approval: serialize_approval(approval),
          phrase_audience_reviews: phrase_reviews,
          blockers: blockers(run, approval, phrase_reviews)
        }
      rescue CandidateBuilder::Error, ArgumentError
        empty_readiness
      end

      private

      attr_reader :persona

      def current_candidate
        expected = CandidateBuilder.snapshot(persona).fetch(:manifest_digest)
        candidate = persona.release_candidates.find_by(manifest_digest: expected)
        candidate if candidate&.integrity_valid?
      end

      def serialize_candidate(candidate)
        {
          id: candidate.id,
          manifest_digest: candidate.manifest_digest,
          audience_digest: candidate.audience_digest,
          draft_revision: candidate.draft_revision,
          sealed_at: candidate.sealed_at
        }
      end

      def serialize_run(run)
        return nil unless run
        {
          id: run.id,
          status: run.status,
          adapter_kind: run.adapter_kind,
          run_digest: run.run_digest,
          passed: run.current_suite_pass?,
          completed_at: run.completed_at
        }
      end

      def serialize_approval(approval)
        return nil unless approval
        {
          id: approval.id,
          decision: approval.decision,
          approval_digest: approval.approval_digest,
          valid: approval.integrity_valid?,
          self_review: approval.self_review?,
          reviewed_at: approval.reviewed_at
        }
      end

      def blockers(run, approval, phrase_reviews)
        values = []
        values << "Run the required persona evaluation." unless run
        values << "The latest evaluation must pass the current case suite without fallback output." if run && !run.current_suite_pass?
        values << "Approve the exact passed evaluation." unless approval&.decision == "approved" && approval&.integrity_valid?
        values << "Review every phrase for this exact audience and culture." unless phrase_reviews.all? { |item| item.fetch(:reviewed) && item.fetch(:decision) == "approved" }
        values
      end

      def empty_readiness
        {
          gate_version: "gate_v2",
          ready: false,
          candidate: nil,
          evaluation_run: nil,
          approval: nil,
          phrase_audience_reviews: [],
          blockers: [ "Run the required persona evaluation for the current draft." ]
        }
      end
    end
  end
end
