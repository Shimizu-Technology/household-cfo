# frozen_string_literal: true

module CoachOperations
  class CohortReleaseRestore < Base
    KEY = "cohort.release.restore"
    VERSION = 1
    INPUT_KEYS = %w[
      expected_latest_release_id source_bundle_digest source_experience_version_id source_persona_version_id
      source_release_id
    ].freeze

    def normalized_input(raw_input)
      input = canonical_input(raw_input, allowed_keys: INPUT_KEYS)
      {
        "expected_latest_release_id" => required_id(input["expected_latest_release_id"], "expected_latest_release_id"),
        "source_bundle_digest" => required_digest(input["source_bundle_digest"], "source_bundle_digest"),
        "source_experience_version_id" => optional_id(
          input["source_experience_version_id"], "source_experience_version_id"
        ),
        "source_persona_version_id" => optional_id(input["source_persona_version_id"], "source_persona_version_id"),
        "source_release_id" => required_id(input["source_release_id"], "source_release_id")
      }
    end

    def predicted_after_snapshot(input)
      state_snapshot.merge(
        "release_count" => cohort.cohort_releases.count + 1,
        "latest_release_id" => nil,
        "latest_release_id_pending" => true,
        "latest_release_number" => cohort.cohort_releases.maximum(:release_number).to_i + 1,
        "latest_bundle_digest" => input.fetch("source_bundle_digest")
      )
    end

    def execute!(prepared, request_key:)
      input = prepared.normalized_input
      source_release = cohort.cohort_releases.find(input.fetch("source_release_id"))
      latest = cohort.cohort_releases.order(release_number: :desc).first
      if source_release.id == latest&.id || source_release.bundle_digest == latest&.bundle_digest
        raise CohortReleases::Sealer::AlreadyRecorded, "The selected release is already the latest sealed record"
      end
      latest_id = latest&.id
      valid_source = latest_id == input.fetch("expected_latest_release_id") &&
        source_release.bundle_digest == input.fetch("source_bundle_digest") &&
        source_release.coach_persona_version_id == input.fetch("source_persona_version_id") &&
        source_release.cohort_experience_version_id == input.fetch("source_experience_version_id")
      raise CohortReleases::Sealer::Stale, "The release history changed; reload before restoring" unless valid_source

      CohortReleases::Sealer.new(cohort: cohort, actor: actor).call!(
        request_key: request_key,
        expected_bundle_digest: input.fetch("source_bundle_digest"),
        event_type: "restore",
        source_release: source_release
      )
    end
  end
end
