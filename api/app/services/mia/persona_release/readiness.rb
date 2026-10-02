# frozen_string_literal: true

module Mia
  module PersonaRelease
    class Readiness
      def initialize(persona:, actor:)
        @persona = persona
        @actor = actor
      end

      def call
        candidate = current_candidate
        return empty_readiness unless candidate

        run = candidate.evaluation_runs.order(id: :desc).first
        approval = run&.approval
        attestations = candidate.phrase_audience_attestations.index_by { |item| item.artifact_id.to_s }
        phrase_reviews = Array(candidate.phrase_artifacts_snapshot).map do |artifact|
          attestation = attestations[artifact.fetch("artifact_id").to_s]
          {
            artifact_id: artifact.fetch("artifact_id"),
            artifact_fingerprint: artifact.fetch("fingerprint"),
            phrase: artifact.slice(*PersonaSchema::PHRASE_AUTHORING_KEYS),
            provenance: {
              kind: artifact.fetch("provenance"),
              source_user_id: artifact.fetch("source_user_id"),
              source_role_at_capture: artifact.fetch("source_role_at_capture")
            },
            decision: attestation&.decision,
            reviewed: attestation&.integrity_valid? == true,
            self_review: attestation&.self_review? == true,
            reviewer: Serializer.user(attestation&.reviewed_by_user),
            reviewed_at: attestation&.reviewed_at,
            attestation_digest: attestation&.attestation_digest
          }
        end
        ready = run&.current_suite_pass? == true && approval&.decision == "approved" && approval.integrity_valid? &&
          phrase_reviews.all? { |review| review.fetch(:reviewed) && review.fetch(:decision) == "approved" }
        {
          gate_version: "gate_v2",
          ready: ready,
          permissions: permissions,
          required_evaluation_cases: SystemCases.catalog.map { |definition| Serializer.system_case_definition(definition) },
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

      attr_reader :persona, :actor

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
          audience_snapshot: candidate.audience_snapshot,
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
          requested_by: Serializer.user(run.requested_by_user),
          completed_at: run.completed_at
        }
      end

      def serialize_approval(approval)
        return nil unless approval
        {
          id: approval.id,
          decision: approval.decision,
          run_digest: approval.run_digest,
          approval_digest: approval.approval_digest,
          valid: approval.integrity_valid?,
          self_review: approval.self_review?,
          reviewer: Serializer.user(approval.reviewed_by_user),
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
          permissions: permissions,
          required_evaluation_cases: SystemCases.catalog.map { |definition| Serializer.system_case_definition(definition) },
          candidate: nil,
          evaluation_run: nil,
          approval: nil,
          phrase_audience_reviews: [],
          blockers: [ "Run the required persona evaluation for the current draft." ]
        }
      end

      def permissions
        workspace = persona.coach_workspace
        active = !persona.archived?
        can_edit = active && workspace&.allows?(actor, :edit) == true
        can_review = active && workspace&.allows?(actor, :review) == true
        membership = workspace&.membership_for(actor)
        {
          manage_cases: can_edit,
          run_evaluation: can_edit,
          review_evaluations: can_review,
          review_phrase_audiences: can_review,
          publish: active && workspace&.allows?(actor, :publish) == true,
          sole_owner_self_review: membership&.role == "owner" &&
            workspace.coach_workspace_memberships.where(role: "owner").count == 1
        }
      end
    end
  end
end
