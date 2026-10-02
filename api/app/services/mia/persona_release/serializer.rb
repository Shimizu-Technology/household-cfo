# frozen_string_literal: true

module Mia
  module PersonaRelease
    class Serializer
      def self.evaluation_case(record)
        {
          id: record.id,
          system_key: record.system_key,
          name: record.name,
          kind: record.case_kind,
          prompt: record.prompt,
          assertions: record.assertions,
          required: record.required?,
          active: record.active?,
          retired_at: record.retired_at,
          retired_by: record.retired_by_user && { id: record.retired_by_user_id, full_name: record.retired_by_user.full_name },
          retirement_digest: record.retirement_digest,
          retirement_valid: record.retirement_integrity_valid?,
          digest: record.case_digest,
          created_at: record.created_at
        }
      end

      def self.run(record, include_results: false)
        payload = {
          id: record.id,
          candidate_id: record.release_candidate.id,
          candidate_digest: record.release_candidate.manifest_digest,
          status: record.status,
          adapter_kind: record.adapter_kind,
          cases_digest: record.cases_digest,
          run_digest: record.run_digest,
          passed: record.current_suite_pass?,
          started_at: record.started_at,
          completed_at: record.completed_at,
          approval: approval(record.approval)
        }
        if include_results
          payload[:results] = record.results.includes(:evaluation_case).order(:id).map do |result|
            {
              id: result.id,
              case: evaluation_case(result.evaluation_case),
              status: result.status,
              output: result.output,
              assertion_results: result.assertion_results,
              adapter_metadata: result.adapter_metadata,
              fallback_only: result.fallback_only?,
              digest: result.result_digest
            }
          end
        end
        payload
      end

      def self.approval(record)
        return nil unless record
        {
          id: record.id,
          decision: record.decision,
          run_digest: record.run_digest,
          approval_digest: record.approval_digest,
          self_review: record.self_review?,
          reviewer: { id: record.reviewed_by_user_id, full_name: record.reviewed_by_user.full_name },
          reviewed_at: record.reviewed_at
        }
      end

      def self.audience_attestation(record)
        {
          id: record.id,
          candidate_id: record.release_candidate.id,
          artifact_id: record.artifact_id,
          artifact_fingerprint: record.artifact_fingerprint,
          audience_digest: record.audience_digest,
          decision: record.decision,
          self_review: record.self_review?,
          attestation_digest: record.attestation_digest,
          reviewed_at: record.reviewed_at
        }
      end
    end
  end
end
