# frozen_string_literal: true

module CohortExperience
  class Publisher
    class PublicationError < StandardError; end
    class PreviewRequiredError < PublicationError; end
    class ReadOnlyError < PublicationError; end

    def initialize(configuration:, actor:)
      @configuration = configuration
      @actor = actor
    end

    def preview!(expected_draft_revision:)
      with_locked_editable_configuration(permission: :review) do
        validate_revision!(expected_draft_revision)
        digest = preview_digest
        configuration.update!(
          preview_digest: digest,
          previewed_draft_revision: configuration.draft_revision,
          previewed_at: Time.current
        )
        digest
      end
    end

    def publish!(expected_preview_digest:, expected_draft_revision:, expected_current_version_id:)
      with_locked_editable_configuration do
        validate_revision!(expected_draft_revision)
        unless normalized_id(expected_current_version_id) == configuration.current_published_version_id
          raise PublicationError, "The published participant tools changed; reload before publishing"
        end
        unless expected_preview_digest.present? &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, configuration.preview_digest.to_s) &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, preview_digest) &&
            configuration.previewed_at.present? &&
            configuration.previewed_draft_revision == configuration.draft_revision
          raise PreviewRequiredError, "Preview this exact participant-tools draft before publishing"
        end

        version = configuration.versions.create!(
          version_number: configuration.versions.maximum(:version_number).to_i + 1,
          config: configuration.draft_config.deep_dup,
          config_digest: CohortExperience::Schema.digest(configuration.draft_config),
          published_by_user: actor
        )
        configuration.update!(current_published_version: version)
        configuration.publication_events.create!(
          cohort_experience_version: version,
          actor_user: actor,
          event_type: "publish"
        )
        version
      end
    end

    private

    attr_reader :configuration, :actor

    def with_locked_editable_configuration(permission: :publish)
      cohort = configuration.cohort
      cohort.with_lock do
        configuration.lock!
        ensure_editable!(cohort, permission: permission)
        yield
      end
    end

    def ensure_editable!(cohort, permission:)
      workspace = configuration.coach_workspace
      allowed = if permission == :review
        workspace&.allows?(actor, :edit) || workspace&.allows?(actor, :review)
      else
        workspace&.allows?(actor, :publish)
      end
      unless allowed
        message = if permission == :review
          "Only a workspace owner, editor, or reviewer can preview participant tools"
        else
          "Only a workspace owner or reviewer can publish participant tools"
        end
        raise PublicationError, message
      end
      raise ReadOnlyError, "Completed and archived cohorts are read-only" unless cohort.status.in?(%w[draft enrolling active])
    end

    def validate_revision!(value)
      return if Integer(value, exception: false) == configuration.draft_revision

      raise PublicationError, "The participant-tools draft changed; reload before continuing"
    end

    def preview_digest
      CohortExperience::Schema.preview_digest(configuration.draft_config, draft_revision: configuration.draft_revision)
    end

    def normalized_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
