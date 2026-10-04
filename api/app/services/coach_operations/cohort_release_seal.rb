# frozen_string_literal: true

module CoachOperations
  class CohortReleaseSeal < Base
    KEY = "cohort.release.seal"
    VERSION = 2
    SUPPORTED_VERSIONS = [ 1, 2 ].freeze
    REPLAY_ONLY_VERSIONS = [ 1 ].freeze
    V1_INPUT_KEYS = %w[
      expected_assignment_id expected_bundle_digest expected_experience_version_id expected_latest_release_id
      expected_persona_version_id expected_tool_registry_digest expected_tool_registry_version
    ].freeze
    V2_INPUT_KEYS = (V1_INPUT_KEYS + %w[expected_brand_version_id]).freeze

    def normalized_input(raw_input)
      input = canonical_input(raw_input, allowed_keys: operation_version == 1 ? V1_INPUT_KEYS : V2_INPUT_KEYS)
      normalized = {
        "expected_assignment_id" => optional_id(input["expected_assignment_id"], "expected_assignment_id"),
        "expected_bundle_digest" => required_digest(input["expected_bundle_digest"], "expected_bundle_digest"),
        "expected_experience_version_id" => optional_id(
          input["expected_experience_version_id"], "expected_experience_version_id"
        ),
        "expected_latest_release_id" => optional_id(input["expected_latest_release_id"], "expected_latest_release_id"),
        "expected_persona_version_id" => optional_id(
          input["expected_persona_version_id"], "expected_persona_version_id"
        ),
        "expected_tool_registry_digest" => required_digest(
          input["expected_tool_registry_digest"], "expected_tool_registry_digest"
        ),
        "expected_tool_registry_version" => required_id(
          input["expected_tool_registry_version"], "expected_tool_registry_version"
        )
      }
      if operation_version == 2
        normalized["expected_brand_version_id"] = optional_id(
          input["expected_brand_version_id"], "expected_brand_version_id"
        )
      end
      normalized
    end

    def predicted_after_snapshot(input)
      state_snapshot.merge(
        "release_count" => cohort.cohort_releases.count + 1,
        "latest_release_id" => nil,
        "latest_release_id_pending" => true,
        "latest_release_number" => cohort.cohort_releases.maximum(:release_number).to_i + 1,
        "latest_bundle_digest" => input.fetch("expected_bundle_digest")
      )
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      verify_current_contract!(input)
      CohortReleases::Sealer.new(cohort: cohort, actor: actor).call!(
        request_key: request_key,
        expected_bundle_digest: input.fetch("expected_bundle_digest"),
        expected_assignment_id: input.fetch("expected_assignment_id"),
        expected_persona_version_id: input.fetch("expected_persona_version_id"),
        expected_experience_version_id: input.fetch("expected_experience_version_id"),
        expected_brand_version_id: input["expected_brand_version_id"]
      )
    end

    private

    def verify_current_contract!(input)
      latest = cohort.cohort_releases.order(release_number: :desc).first
      if latest&.bundle_digest == input.fetch("expected_bundle_digest")
        raise CohortReleases::Sealer::AlreadyRecorded, "This exact cohort release bundle is already sealed"
      end
      latest_id = latest&.id
      unless latest_id == input.fetch("expected_latest_release_id")
        raise CohortReleases::Sealer::Stale, "The latest sealed record changed; reload before sealing"
      end
      candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
      raise CohortReleases::Sealer::Incomplete, candidate.blockers if candidate.blockers.any?

      registry = candidate.tool_registry_snapshot
      actual_digest = CohortReleases::Contract.digest(registry)
      valid = input.fetch("expected_tool_registry_version") == registry.fetch("schema_version") &&
        input.fetch("expected_tool_registry_digest") == actual_digest
      raise CohortReleases::Sealer::Stale, "The operation registry changed; reload before sealing" unless valid

      components_match = input.fetch("expected_assignment_id") == candidate.assignment&.id &&
        input.fetch("expected_persona_version_id") == candidate.persona_version&.id &&
        input.fetch("expected_experience_version_id") == candidate.experience_version&.id
      if operation_version == 2
        components_match &&= input.fetch("expected_brand_version_id") == candidate.brand_version&.id
      end
      raise CohortReleases::Sealer::Stale, "The cohort release inputs changed; reload before sealing" unless components_match
    end
  end
end
