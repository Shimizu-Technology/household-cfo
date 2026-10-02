# frozen_string_literal: true

module Mia
  module PersonaRelease
    class RunApprover
      class Error < StandardError; end

      def initialize(run:, actor:)
        @run = run
        @actor = actor
      end

      def call!(decision:, expected_run_digest:)
        workspace = run.release_candidate.coach_persona.coach_workspace
        raise Error, "Only a workspace owner or reviewer can approve an evaluation" unless workspace&.allows?(actor, :review)

        run.with_lock do
          existing = run.approval
          return existing if existing&.integrity_valid? && existing.decision == decision.to_s &&
            secure_match?(existing.run_digest, expected_run_digest)
          raise Error, "This evaluation run was already reviewed" if existing
          unless run.current_suite_pass? && secure_match?(run.run_digest, expected_run_digest)
            raise Error, "Only the exact intact passed evaluation can be approved"
          end
          raise Error, "Choose approve or reject" unless decision.to_s.in?(CoachPersonaEvaluationApproval::DECISIONS)

          self_review = ReviewRules.self_review!(
            workspace: workspace,
            actor: actor,
            self_review: run.requested_by_user_id == actor.id
          )
          reviewed_at = Time.current
          authority_snapshot, authority_digest = ReviewAuthority.snapshot(workspace: workspace, actor: actor)
          approval = run.build_approval(
            reviewed_by_user: actor,
            decision: decision,
            self_review: self_review,
            run_digest: run.run_digest,
            reviewed_at: reviewed_at,
            reviewer_role_snapshot: authority_snapshot.fetch("role"),
            reviewer_authority_snapshot: authority_snapshot,
            reviewer_authority_digest: authority_digest
          )
          approval.approval_digest = CoachPersonaEvaluationApproval.digest_for(
            run: run,
            reviewer_id: actor.id,
            decision: decision,
            self_review: self_review,
            reviewed_at: reviewed_at,
            reviewer_authority_snapshot: authority_snapshot,
            reviewer_authority_digest: authority_digest
          )
          approval.save!
          approval
        end
      rescue ReviewRules::Error, ActiveRecord::RecordInvalid => error
        raise Error, error.message
      end

      private

      attr_reader :run, :actor

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
