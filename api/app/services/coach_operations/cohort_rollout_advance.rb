# frozen_string_literal: true

module CoachOperations
  class CohortRolloutAdvance < CohortRolloutOperation
    KEY = "cohort.rollout.advance"
    VERSION = 2
    INPUT_KEYS = (COMMON_CAS_KEYS + %w[readiness_digest]).freeze

    def normalize_operation_input(input)
      normalize_common_cas(input).merge(
        "readiness_digest" => required_digest(input["readiness_digest"], "readiness_digest")
      )
    end

    def predicted_after_snapshot(input)
      rollout = prepared_rollout || find_rollout(input.fetch("rollout_id"))
      current_position = input.fetch("expected_current_wave_position")
      planned = input.fetch("expected_status") == "planned"
      final_wave = !planned && current_position >= rollout.waves.maximum(:position).to_i
      predicted_rollout_snapshot(
        status: final_wave ? "completed" : "active",
        wave_position: final_wave ? current_position : (planned ? 1 : current_position + 1),
        participant_runtime_changed: runtime_cutover?
      )
    end

    def prepared_before_snapshot(input)
      super.merge("readiness_digest" => input.fetch("readiness_digest"))
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      state_machine.advance!(
        rollout: find_rollout(input.fetch("rollout_id")),
        input: machine_input(input)
      )
    end
  end
end
