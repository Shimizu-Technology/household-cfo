# frozen_string_literal: true

module Mia
  class PersonaStudioSerializer
    GUARDRAILS = [
      "Use only approved household financial facts.",
      "Keep the participant in control of every financial write.",
      "Do not provide licensed advice or bypass crisis handling.",
      "Do not imitate accents or invent cultural stereotypes."
    ].freeze

    def initialize(persona, policy:)
      @persona = persona
      @policy = policy
    end

    def summary
      {
        id: persona.id,
        name: persona.name,
        description: persona.description.to_s,
        role: persona.draft_config.dig("identity", "assistant_relationship"),
        status: status,
        draft_revision: persona.draft_revision,
        has_unpublished_changes: unpublished_changes?,
        preview_required: preview_required?,
        owner: serialize_user(persona.created_by_user),
        published_version: serialize_version(persona.current_published_version),
        visible_assignment_count: visible_assignments.count,
        updated_at: persona.updated_at,
        permissions: permissions
      }
    end

    def detail
      summary.merge(
        draft: persona.draft_config,
        guardrails: {
          editable: false,
          source: "Household CFO system",
          rules: GUARDRAILS
        },
        preview: serialize_preview,
        versions: persona.versions.includes(:published_by_user, :source_version).order(version_number: :desc).map { |version| serialize_version(version, include_source: true) },
        assignments: visible_assignments.includes(:cohort, :assigned_by_user, :coach_persona_version).order(created_at: :desc).map { |assignment| serialize_assignment(assignment) }
      )
    end

    def serialize_assignment(assignment)
      {
        id: assignment.id,
        cohort: {
          id: assignment.cohort.id,
          name: assignment.cohort.name,
          status: assignment.cohort.status
        },
        persona: {
          id: persona.id,
          name: persona.name
        },
        published_version: serialize_version(assignment.coach_persona_version),
        assigned_at: assignment.created_at,
        updated_at: assignment.updated_at,
        assigned_by: serialize_user(assignment.assigned_by_user)
      }
    end

    def serialize_version(version, include_config: false, include_source: false)
      return nil unless version

      payload = {
        id: version.id,
        number: version.version_number,
        digest: version.config_digest,
        published_at: version.created_at,
        published_by: serialize_user(version.published_by_user)
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

    attr_reader :persona, :policy

    def status
      return "archived" if persona.archived?
      return "published" if persona.published?

      "draft"
    end

    def unpublished_changes?
      return true unless persona.current_published_version

      persona.current_published_version.config_digest != PersonaSchema.digest(persona.draft_config)
    end

    def preview_required?
      return true if persona.preview_digest.blank? || persona.previewed_draft_revision != persona.draft_revision

      persona.preview_digest != PersonaPromptBuilder.digest(persona.draft_config, draft_revision: persona.draft_revision)
    end

    def serialize_preview
      return nil if persona.preview_digest.blank?

      {
        digest: persona.preview_digest,
        draft_revision: persona.previewed_draft_revision,
        generated_at: persona.previewed_at
      }
    end

    def permissions
      editable = policy.can_edit?(persona)
      {
        read: true,
        edit: editable && !persona.archived?,
        publish: editable && !persona.archived?,
        assign: policy.can_assign?(persona),
        archive: editable && persona.cohort_persona_assignments.none?
      }
    end

    def visible_assignments
      @visible_assignments ||= persona.cohort_persona_assignments.where(cohort_id: policy.manageable_cohorts.select(:id))
    end

    def serialize_user(user)
      return nil unless user

      {
        id: user.id,
        email: user.email,
        full_name: user.full_name
      }
    end
  end
end
