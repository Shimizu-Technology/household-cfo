# frozen_string_literal: true

module CoachOperations
  class Base
    class InvalidInput < ArgumentError; end

    def initialize(cohort:, actor:, actor_role_snapshot:)
      @cohort = cohort
      @actor = actor
      @actor_role_snapshot = actor_role_snapshot
    end

    def prepare(raw_input)
      input = normalized_input(raw_input)
      PreparedOperation.new(
        operation_key: self.class::KEY,
        operation_version: self.class::VERSION,
        normalized_input: input,
        before_snapshot: state_snapshot,
        predicted_after_snapshot: predicted_after_snapshot(input)
      )
    end

    def after_snapshot(_release)
      state_snapshot
    end

    private

    attr_reader :cohort, :actor, :actor_role_snapshot

    def canonical_input(value, allowed_keys:)
      raise InvalidInput, "Operation input must be an object" unless value.respond_to?(:to_h)

      input = value.to_h.deep_stringify_keys
      unknown = input.keys - allowed_keys
      raise InvalidInput, "Unsupported operation input: #{unknown.sort.join(', ')}" if unknown.any?
      missing = allowed_keys - input.keys
      raise InvalidInput, "Missing operation input: #{missing.sort.join(', ')}" if missing.any?

      Contract.canonicalize(input)
    end

    def required_digest(value, name)
      digest = value.to_s.strip
      raise InvalidInput, "#{name} must be a SHA-256 digest" unless digest.match?(/\A[0-9a-f]{64}\z/)

      digest
    end

    def required_id(value, name)
      id = case value
      when Integer
        value
      when /\A[1-9][0-9]*\z/
        Integer(value, 10)
      end
      raise InvalidInput, "#{name} must be a positive integer" unless id&.positive?

      id
    end

    def optional_id(value, name)
      return nil if value.nil?

      required_id(value, name)
    end

    def state_snapshot
      latest = cohort.cohort_releases.order(release_number: :desc).first
      {
        "schema" => "cohort_release_state_v1",
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "release_count" => cohort.cohort_releases.count,
        "latest_release_id" => latest&.id,
        "latest_release_number" => latest&.release_number,
        "latest_bundle_digest" => latest&.bundle_digest,
        "participant_runtime_changed" => false
      }
    end
  end
end
