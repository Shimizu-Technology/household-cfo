# frozen_string_literal: true

module CoachOperations
  class CohortReleaseSeal < Base
    KEY = "cohort.release.seal"
    VERSION = 1
    INPUT_KEYS = %w[
      expected_assignment_id expected_bundle_digest expected_experience_version_id expected_latest_release_id
      expected_persona_version_id expected_tool_registry_digest expected_tool_registry_version
    ].freeze

    def normalized_input(raw_input)
      input = canonical_input(raw_input, allowed_keys: INPUT_KEYS)
      {
        "expected_assignment_id" => required_id(input["expected_assignment_id"], "expected_assignment_id"),
        "expected_bundle_digest" => required_digest(input["expected_bundle_digest"], "expected_bundle_digest"),
        "expected_experience_version_id" => required_id(
          input["expected_experience_version_id"], "expected_experience_version_id"
        ),
        "expected_latest_release_id" => optional_id(input["expected_latest_release_id"], "expected_latest_release_id"),
        "expected_persona_version_id" => required_id(
          input["expected_persona_version_id"], "expected_persona_version_id"
        ),
        "expected_tool_registry_digest" => required_digest(
          input["expected_tool_registry_digest"], "expected_tool_registry_digest"
        ),
        "expected_tool_registry_version" => required_id(
          input["expected_tool_registry_version"], "expected_tool_registry_version"
        )
      }
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
        expected_experience_version_id: input.fetch("expected_experience_version_id")
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
      registry = CohortReleases::Contract.tool_registry_snapshot
      actual_digest = CohortReleases::Contract.digest(registry)
      valid = input.fetch("expected_tool_registry_version") == CohortReleases::Contract::TOOL_REGISTRY_VERSION &&
        input.fetch("expected_tool_registry_digest") == actual_digest
      raise CohortReleases::Sealer::Stale, "The operation registry changed; reload before sealing" unless valid
    end
  end
end
