# frozen_string_literal: true

module CoachOperations
  module Contract
    module_function

    def digest(value)
      CohortReleases::Contract.digest(value)
    end

    def canonicalize(value)
      CohortReleases::Contract.canonicalize(value)
    end

    def invocation_fingerprint(cohort_id:, coach_workspace_id:, actor_user_id:, actor_role_snapshot:,
      operation_key:, operation_version:, normalized_input:)
      digest(
        "schema" => "coach_operation_invocation_v1",
        "cohort_id" => cohort_id,
        "coach_workspace_id" => coach_workspace_id,
        "actor_user_id" => actor_user_id,
        "actor_role_snapshot" => actor_role_snapshot,
        "operation_key" => operation_key,
        "operation_version" => operation_version,
        "normalized_input" => normalized_input
      )
    end

    def request_fingerprint(request_key:, invocation_fingerprint:)
      digest(
        "schema" => "coach_operation_request_v1",
        "request_key" => request_key,
        "invocation_fingerprint" => invocation_fingerprint
      )
    end
  end
end
