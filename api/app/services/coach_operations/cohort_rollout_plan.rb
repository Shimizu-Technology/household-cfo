# frozen_string_literal: true

module CoachOperations
  class CohortRolloutPlan < CohortRolloutOperation
    KEY = "cohort.rollout.plan"
    VERSION = 2
    INPUT_KEYS = %w[expected_latest_release_id expected_roster_digest target_release_id waves].freeze
    MAX_WAVES = 25
    MAX_PARTICIPANTS = 500

    def prepare(raw_input)
      input = normalized_input(raw_input)
      before_snapshot = state_snapshot.merge(
        "latest_release_id" => cohort.cohort_releases.order(release_number: :desc).pick(:id),
        "participant_roster_digest" => CohortRollouts::Contract.roster_digest(cohort)
      )
      PreparedOperation.new(
        operation_key: self.class::KEY,
        operation_version: operation_version,
        normalized_input: input,
        before_snapshot: before_snapshot,
        predicted_after_snapshot: predicted_after_snapshot(input)
      )
    end

    def normalize_operation_input(input)
      waves = normalize_waves(input.fetch("waves"))
      {
        "target_release_id" => required_id(input["target_release_id"], "target_release_id"),
        "expected_latest_release_id" => required_id(
          input["expected_latest_release_id"], "expected_latest_release_id"
        ),
        "expected_roster_digest" => required_digest(input["expected_roster_digest"], "expected_roster_digest"),
        "waves" => waves
      }
    end

    def predicted_after_snapshot(input)
      state_snapshot.merge(
        "rollout_id" => nil,
        "rollout_id_pending" => true,
        "target_release_id" => input.fetch("target_release_id"),
        "rollback_release_id" => nil,
        "status" => "planned",
        "current_wave_position" => 0,
        "latest_transition_id" => nil,
        "latest_transition_id_pending" => true
      )
    end

    def execute!(prepared, request_key:)
      state_machine.plan!(machine_input(prepared.normalized_input))
    end

    private

    def normalize_waves(value)
      unless value.is_a?(Array) && value.length.between?(1, MAX_WAVES)
        raise InvalidInput, "waves must contain between 1 and #{MAX_WAVES} wave objects"
      end

      participant_ids = []
      waves = value.map.with_index do |raw_wave, index|
        unless raw_wave.respond_to?(:to_h)
          raise InvalidInput, "waves[#{index}] must be an object"
        end

        wave = raw_wave.to_h.deep_stringify_keys
        unknown = wave.keys - %w[name user_ids]
        missing = %w[name user_ids] - wave.keys
        raise InvalidInput, "Unsupported waves[#{index}] input: #{unknown.sort.join(', ')}" if unknown.any?
        raise InvalidInput, "Missing waves[#{index}] input: #{missing.sort.join(', ')}" if missing.any?

        name = wave.fetch("name").to_s.squish
        unless name.present? && name.length <= 80
          raise InvalidInput, "waves[#{index}].name must be between 1 and 80 characters"
        end
        raw_ids = wave.fetch("user_ids")
        unless raw_ids.is_a?(Array) && raw_ids.any?
          raise InvalidInput, "waves[#{index}].user_ids must be a nonempty array"
        end
        user_ids = raw_ids.map { |id| required_id(id, "waves[#{index}].user_ids") }.uniq.sort
        if user_ids.length != raw_ids.length
          raise InvalidInput, "waves[#{index}].user_ids must not contain duplicates"
        end
        participant_ids.concat(user_ids)
        { "name" => name, "user_ids" => user_ids }
      end

      if participant_ids.length > MAX_PARTICIPANTS
        raise InvalidInput, "waves may include at most #{MAX_PARTICIPANTS} participants"
      end
      if participant_ids.uniq.length != participant_ids.length
        raise InvalidInput, "each participant must appear in exactly one wave"
      end

      waves
    end
  end
end
