# frozen_string_literal: true

module CoachOperations
  class CohortRolloutPause < CohortRolloutOperation
    KEY = "cohort.rollout.pause"
    VERSION = 2
    INPUT_KEYS = COMMON_CAS_KEYS

    def normalize_operation_input(input) = normalize_common_cas(input)

    def predicted_after_snapshot(input)
      predicted_rollout_snapshot(status: "paused", wave_position: input.fetch("expected_current_wave_position"))
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      state_machine.pause!(
        rollout: find_rollout(input.fetch("rollout_id")),
        input: machine_input(input)
      )
    end
  end
end
