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
        behavioral_preview = candidate.behavioral_preview_evidences.order(id: :desc).first
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
            reviewer_role: attestation&.reviewer_role_snapshot,
            reviewer_authority_digest: attestation&.reviewer_authority_digest,
            reviewed_at: attestation&.reviewed_at,
            attestation_digest: attestation&.attestation_digest
          }
        end
        authority_current = review_authority_current?(approval, attestations.values.compact)
        ready = publication_needed? && authority_current && behavioral_preview&.integrity_valid? == true && run&.current_suite_pass? == true &&
          approval&.decision == "approved" && approval.integrity_valid? &&
          phrase_reviews.all? { |review| review.fetch(:reviewed) && review.fetch(:decision) == "approved" }
        {
          gate_version: "gate_v2",
          ready: ready,
          permissions: permissions,
          required_evaluation_cases: SystemCases.catalog.map { |definition| Serializer.system_case_definition(definition) },
          evaluation_case_contract: Serializer.evaluation_case_contract,
          candidate: serialize_candidate(candidate),
          behavioral_preview_evidence: Serializer.behavioral_preview(behavioral_preview),
          evaluation_run: serialize_run(run),
          approval: serialize_approval(approval),
          phrase_audience_reviews: phrase_reviews,
          blockers: blockers(run, approval, behavioral_preview, phrase_reviews, authority_current)
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

        Serializer.run(run)
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
          reviewer_role: approval.reviewer_role_snapshot,
          reviewer_authority_digest: approval.reviewer_authority_digest,
          reviewed_at: approval.reviewed_at
        }
      end

      def blockers(run, approval, behavioral_preview, phrase_reviews, authority_current)
        values = []
        values << "Change the persona draft before publishing another version." unless publication_needed?
        values << "Run and save a live behavioral preview for this exact release candidate." unless behavioral_preview&.integrity_valid?
        values << "Run the required persona evaluation." unless run
        values << "The latest evaluation must pass the current case suite without fallback output." if run && !run.current_suite_pass?
        values << "Approve the exact passed evaluation." unless approval&.decision == "approved" && approval&.integrity_valid?
        values << "Review every phrase for this exact audience and culture." unless phrase_reviews.all? { |item| item.fetch(:reviewed) && item.fetch(:decision) == "approved" }
        values << "A reviewer lost workspace review access; collect fresh review evidence." unless authority_current
        values
      end

      def review_authority_current?(approval, attestations)
        reviews = [ approval, *attestations ].compact
        reviews.all? { |review| persona.coach_workspace.allows?(review.reviewed_by_user, :review) }
      end

      def empty_readiness
        {
          gate_version: "gate_v2",
          ready: false,
          permissions: permissions,
          required_evaluation_cases: SystemCases.catalog.map { |definition| Serializer.system_case_definition(definition) },
          evaluation_case_contract: Serializer.evaluation_case_contract,
          candidate: nil,
          behavioral_preview_evidence: nil,
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
          publish: active && publication_needed? && workspace&.allows?(actor, :publish) == true,
          publication_needed: publication_needed?,
          sole_owner_self_review: membership&.role == "owner" &&
            workspace.coach_workspace_memberships.where(role: "owner").count == 1
        }
      end

      def publication_needed?
        version = persona.current_published_version
        return true unless version

        version.config_digest != PersonaSchema.digest(persona.draft_config) ||
          version.content_manifest_digest != persona.draft_content_manifest_digest ||
          version.phrase_manifest_digest != persona.draft_phrase_manifest_digest
      rescue ArgumentError
        true
      end
    end
  end
end
