# frozen_string_literal: true

module CoachOperations
  class CohortReleaseRestore < Base
    KEY = "cohort.release.restore"
    VERSION = 2
    SUPPORTED_VERSIONS = [ 1, 2 ].freeze
    REPLAY_ONLY_VERSIONS = [ 1 ].freeze
    V1_INPUT_KEYS = %w[
      expected_latest_release_id source_bundle_digest source_experience_version_id source_persona_version_id
      source_release_id
    ].freeze
    V2_INPUT_KEYS = (V1_INPUT_KEYS + %w[source_brand_version_id]).freeze

    def normalized_input(raw_input)
      input = canonical_input(raw_input, allowed_keys: operation_version == 1 ? V1_INPUT_KEYS : V2_INPUT_KEYS)
      normalized = {
        "expected_latest_release_id" => required_id(input["expected_latest_release_id"], "expected_latest_release_id"),
        "source_bundle_digest" => required_digest(input["source_bundle_digest"], "source_bundle_digest"),
        "source_experience_version_id" => optional_id(
          input["source_experience_version_id"], "source_experience_version_id"
        ),
        "source_persona_version_id" => optional_id(input["source_persona_version_id"], "source_persona_version_id"),
        "source_release_id" => required_id(input["source_release_id"], "source_release_id")
      }
      if operation_version == 2
        normalized["source_brand_version_id"] = optional_id(
          input["source_brand_version_id"], "source_brand_version_id"
        )
      end
      normalized
    end

    def predicted_after_snapshot(input)
      digest = input.fetch("source_bundle_digest")
      if operation_version == 2
        source = cohort.cohort_releases.find(input.fetch("source_release_id"))
        digest = CohortReleases::RestoreCandidateBuilder.new(cohort: cohort, source_release: source).call.bundle_digest
      end
      state_snapshot.merge(
        "release_count" => cohort.cohort_releases.count + 1,
        "latest_release_id" => nil,
        "latest_release_id_pending" => true,
        "latest_release_number" => cohort.cohort_releases.maximum(:release_number).to_i + 1,
        "latest_bundle_digest" => digest
      )
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      source_release = cohort.cohort_releases.find(input.fetch("source_release_id"))
      candidate = CohortReleases::RestoreCandidateBuilder.new(cohort: cohort, source_release: source_release).call
      latest = cohort.cohort_releases.order(release_number: :desc).first
      if source_release.id == latest&.id || candidate.bundle_digest == latest&.bundle_digest
        raise CohortReleases::Sealer::AlreadyRecorded, "The selected release is already the latest sealed record"
      end
      latest_id = latest&.id
      valid_source = latest_id == input.fetch("expected_latest_release_id") &&
        source_release.bundle_digest == input.fetch("source_bundle_digest") &&
        source_release.coach_persona_version_id == input.fetch("source_persona_version_id") &&
        source_release.cohort_experience_version_id == input.fetch("source_experience_version_id")
      if operation_version == 2
        valid_source &&= source_release.workspace_brand_version_id == input.fetch("source_brand_version_id")
      end
      raise CohortReleases::Sealer::Stale, "The release history changed; reload before restoring" unless valid_source

      CohortReleases::Sealer.new(cohort: cohort, actor: actor).call!(
        request_key: request_key,
        expected_bundle_digest: candidate.bundle_digest,
        expected_brand_version_id: candidate.brand_version&.id,
        event_type: "restore",
        source_release: source_release
      )
    end
  end
end
