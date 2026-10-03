# frozen_string_literal: true

module CoachOperations
  class CohortRolloutOperation < Base
    VERSION = 1
    COMMON_CAS_KEYS = %w[
      expected_current_wave_position expected_latest_transition_id expected_status rollout_id
    ].freeze
    STATUSES = %w[planned active paused completed cancelled rolled_back].freeze

    def normalized_input(raw_input)
      input = canonical_input(raw_input, allowed_keys: self.class::INPUT_KEYS)
      normalize_operation_input(input)
    end

    def prepare(raw_input)
      input = normalized_input(raw_input)
      @prepared_rollout = find_rollout(input["rollout_id"]) if input.key?("rollout_id")
      PreparedOperation.new(
        operation_key: self.class::KEY,
        operation_version: self.class::VERSION,
        normalized_input: input,
        before_snapshot: prepared_before_snapshot(input),
        predicted_after_snapshot: predicted_after_snapshot(input)
      )
    end

    def after_snapshot(transition)
      CohortRollouts::Contract.state_snapshot(cohort: cohort, rollout: transition.cohort_rollout)
    end

    private

    attr_reader :prepared_rollout

    def state_snapshot
      CohortRollouts::Contract.state_snapshot(cohort: cohort, rollout: prepared_rollout)
    end

    def prepared_before_snapshot(_input)
      state_snapshot
    end

    def normalize_common_cas(input)
      {
        "rollout_id" => required_id(input["rollout_id"], "rollout_id"),
        "expected_status" => required_status(input["expected_status"]),
        "expected_current_wave_position" => required_nonnegative_integer(
          input["expected_current_wave_position"], "expected_current_wave_position"
        ),
        "expected_latest_transition_id" => required_id(
          input["expected_latest_transition_id"], "expected_latest_transition_id"
        )
      }
    end

    def state_machine
      CohortRollouts::StateMachine.new(
        cohort: cohort,
        actor: actor,
        actor_role_snapshot: actor_role_snapshot
      )
    end

    def find_rollout(id)
      cohort.cohort_rollouts.find(id)
    rescue ActiveRecord::RecordNotFound
      raise InvalidInput, "rollout_id must identify a rollout in this cohort"
    end

    def machine_input(input)
      input.except("rollout_id").symbolize_keys
    end

    def required_status(value)
      status = value.to_s
      raise InvalidInput, "expected_status is unsupported" unless status.in?(STATUSES)

      status
    end

    def required_nonnegative_integer(value, name)
      integer = case value
      when Integer
        value
      when /\A(?:0|[1-9][0-9]*)\z/
        Integer(value, 10)
      end
      raise InvalidInput, "#{name} must be a nonnegative integer" unless integer && integer >= 0

      integer
    end

    def transition_from(result)
      result.respond_to?(:transition) ? result.transition : result
    end

    def predicted_rollout_snapshot(status:, wave_position:, rollback_release_id: nil)
      state_snapshot.merge(
        "status" => status,
        "current_wave_position" => wave_position,
        "latest_transition_id" => nil,
        "latest_transition_id_pending" => true,
        "rollback_release_id" => rollback_release_id
      )
    end
  end
end
