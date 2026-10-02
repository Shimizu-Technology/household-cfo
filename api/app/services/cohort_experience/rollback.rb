# frozen_string_literal: true

module CohortExperience
  class Rollback
    class RollbackError < StandardError; end
    class ReadOnlyError < RollbackError; end

    def initialize(configuration:, target_version:, actor:)
      @configuration = configuration
      @target_version = target_version
      @actor = actor
    end

    def call(expected_current_version_id:, expected_draft_revision:)
      with_locked_editable_configuration do
        unless Integer(expected_draft_revision, exception: false) == configuration.draft_revision
          raise RollbackError, "The participant-tools draft changed; reload before restoring"
        end
        unless normalized_id(expected_current_version_id) == configuration.current_published_version_id
          raise RollbackError, "The published participant tools changed; reload before restoring"
        end

        restored = configuration.versions.create!(
          version_number: configuration.versions.maximum(:version_number).to_i + 1,
          config: target_version.config.deep_dup,
          config_digest: target_version.config_digest,
          published_by_user: actor,
          source_version: target_version
        )
        configuration.apply_rollback_version!(restored, actor: actor)
        configuration.publication_events.create!(
          cohort_experience_version: restored,
          source_version: target_version,
          actor_user: actor,
          event_type: "rollback"
        )
        restored
      end
    end

    private

    attr_reader :configuration, :target_version, :actor

    def with_locked_editable_configuration
      cohort = configuration.cohort
      cohort.with_lock do
        configuration.lock!
        ensure_editable!(cohort)
        yield
      end
    end

    def ensure_editable!(cohort)
      unless configuration.coach_workspace&.allows?(actor, :publish)
        raise RollbackError, "Only a workspace owner or reviewer can publish participant tools"
      end
      raise ReadOnlyError, "Completed and archived cohorts are read-only" unless cohort.status.in?(%w[draft enrolling active])
      raise RollbackError, "Version does not belong to this cohort" unless target_version.cohort_experience_configuration_id == configuration.id
    end

    def normalized_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
