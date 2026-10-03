# frozen_string_literal: true

module CoachOperations
  class CohortRolloutRollback < CohortRolloutOperation
    KEY = "cohort.rollout.rollback"
    VERSION = 2
    INPUT_KEYS = (COMMON_CAS_KEYS + %w[rollback_release_id]).freeze

    def normalize_operation_input(input)
      normalize_common_cas(input).merge(
        "rollback_release_id" => required_id(input["rollback_release_id"], "rollback_release_id")
      )
    end

    def predicted_after_snapshot(input)
      predicted_rollout_snapshot(
        status: "rolled_back",
        wave_position: input.fetch("expected_current_wave_position"),
        rollback_release_id: input.fetch("rollback_release_id"),
        participant_runtime_changed: runtime_cutover?
      )
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      state_machine.rollback!(
        rollout: find_rollout(input.fetch("rollout_id")),
        input: machine_input(input)
      )
    end
  end
end
