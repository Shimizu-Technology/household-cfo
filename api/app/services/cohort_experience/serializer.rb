# frozen_string_literal: true

module CohortExperience
  class Serializer
    def initialize(configuration:)
      @configuration = configuration
    end

    def detail
      {
        cohort: {
          id: cohort.id,
          name: cohort.name,
          status: cohort.status,
          participant_count: cohort.cohort_memberships.where(role: "participant").count
        },
        draft: configuration.draft_config,
        draft_revision: configuration.draft_revision,
        preview_required: preview_required?,
        preview: configuration.preview_digest && {
          digest: configuration.preview_digest,
          draft_revision: configuration.previewed_draft_revision,
          generated_at: configuration.previewed_at
        },
        published_version: serialize_version(configuration.current_published_version),
        versions: configuration.versions.order(version_number: :desc).map { |version| serialize_version(version, include_source: true) },
        permissions: {
          edit: cohort.status.in?(%w[draft enrolling active]),
          publish: cohort.status.in?(%w[draft enrolling active]),
          rollback: cohort.status.in?(%w[draft enrolling active])
        }
      }
    end

    def serialize_version(version, include_config: false, include_source: false)
      return nil unless version

      payload = {
        id: version.id,
        number: version.version_number,
        digest: version.config_digest,
        published_at: version.created_at,
        published_by: { id: version.published_by_user_id, full_name: version.published_by_user.full_name }
      }
      payload[:config] = version.config if include_config
      if include_source
        payload[:restored_from_version] = version.source_version && {
          id: version.source_version.id,
          number: version.source_version.version_number
        }
      end
      payload
    end

    private

    attr_reader :configuration

    def cohort
      configuration.cohort
    end

    def preview_required?
      return true unless configuration.preview_digest && configuration.previewed_draft_revision == configuration.draft_revision

      current = CohortExperience::Schema.preview_digest(configuration.draft_config, draft_revision: configuration.draft_revision)
      !ActiveSupport::SecurityUtils.secure_compare(configuration.preview_digest, current)
    end
  end
end
