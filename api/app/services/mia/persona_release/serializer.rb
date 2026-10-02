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
          request_id: record.request_key,
          created_at: record.created_at
        }
      end

      def self.system_case_definition(definition, record: nil)
        return evaluation_case(record) if record

        {
          id: nil,
          system_key: definition.fetch(:system_key),
          name: definition.fetch(:name),
          kind: "system",
          prompt: definition.fetch(:prompt),
          assertions: definition.fetch(:assertions),
          required: true,
          active: true,
          retired_at: nil,
          retired_by: nil,
          retirement_digest: nil,
          retirement_valid: true,
          digest: definition.fetch(:case_digest),
          request_id: nil,
          created_at: nil
        }
      end

      def self.evaluation_case_contract
        {
          name_max_chars: 120,
          prompt_max_chars: 2_000,
          max_active_custom_cases: Runner::MAX_CASES - SystemCases::DEFINITIONS.length,
          assertion_types: AssertionEvaluator::TYPES,
          assertions_min: 1,
          assertions_max: AssertionEvaluator::MAX_ASSERTIONS,
          assertion_value_max_chars: AssertionEvaluator::MAX_VALUE_LENGTH,
          assertion_values_max: AssertionEvaluator::MAX_VALUES,
          max_chars_range: { min: 1, max: 20_000 }
        }
      end

      def self.run(record, include_results: false, current_suite: true)
        payload = {
          id: record.id,
          candidate_id: record.release_candidate.id,
          candidate_digest: record.release_candidate.manifest_digest,
          request_id: record.request_key,
          status: record.status,
          adapter_kind: record.adapter_kind,
          cases_digest: record.cases_digest,
          run_digest: record.run_digest,
          passed: current_suite ? record.current_suite_pass? : record.passed_and_valid?,
          started_at: record.started_at,
          completed_at: record.completed_at,
          enqueued_at: record.enqueued_at,
          execution: {
            active_lease: record.execution_lease_active?,
            recoverable: record.recoverable?,
            heartbeat_at: record.heartbeat_at,
            lease_expires_at: record.lease_expires_at,
            poll_after_ms: record.terminal? ? nil : 2_000,
            retry_action: record.recoverable? ? "replay_same_request" : nil
          },
          requested_by: user(record.requested_by_user),
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
              model_identifier: result.adapter_metadata["model_identifier"],
              provider_request_id: result.adapter_metadata["provider_request_id"],
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
          reviewer_role: record.reviewer_role_snapshot,
          reviewer_authority_digest: record.reviewer_authority_digest,
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
          reviewer: user(record.reviewed_by_user),
          reviewer_role: record.reviewer_role_snapshot,
          reviewer_authority_digest: record.reviewer_authority_digest,
          attestation_digest: record.attestation_digest,
          reviewed_at: record.reviewed_at
        }
      end

      def self.behavioral_preview(record)
        return nil unless record

        {
          id: record.id,
          candidate_id: record.release_candidate.id,
          candidate_digest: record.candidate_digest,
          config_digest: record.config_digest,
          content_manifest_digest: record.content_manifest_digest,
          phrase_manifest_digest: record.phrase_manifest_digest,
          prompt: record.prompt,
          output: record.output,
          source: record.response_source,
          model: record.model_identifier,
          provider_request_id: record.provider_request_id,
          privacy_scope: record.privacy_scope,
          context_digest: record.context_digest,
          generated_by: user(record.generated_by_user),
          generated_at: record.generated_at,
          digest: record.evidence_digest,
          valid: record.integrity_valid?
        }
      end


      def self.user(record)
        return nil unless record

        { id: record.id, full_name: record.full_name }
      end
    end
  end
end
