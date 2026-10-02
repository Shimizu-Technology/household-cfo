# frozen_string_literal: true

module Mia
  class PersonaStudioSerializer
    GUARDRAILS = [
      "Use only approved household financial facts.",
      "Keep the participant in control of every financial write.",
      "Do not provide licensed advice or bypass crisis handling.",
      "Do not imitate accents or invent cultural stereotypes.",
      "Do not paste cultural mimicry into a prohibition; state the safe allowed behavior instead."
    ].freeze

    def initialize(persona, policy:)
      @persona = persona
      @policy = policy
    end

    def summary
      payload = {
        id: persona.id,
        name: display_config.dig("identity", "assistant_name") || persona.name,
        description: private_configuration_visible? ? persona.description.to_s : "",
        role: display_config.dig("identity", "assistant_relationship"),
        status: status,
        owner: serialize_user(persona.created_by_user),
        workspace: {
          id: persona.coach_workspace_id,
          name: persona.coach_workspace.name,
          coach_name: persona.coach_workspace.coach_profile&.display_name
        },
        published_version: serialize_version(persona.current_published_version),
        visible_assignment_count: visible_assignments.count,
        updated_at: persona.updated_at,
        permissions: permissions
      }
      if private_configuration_visible?
        payload.merge!(
          draft_revision: persona.draft_revision,
          has_unpublished_changes: unpublished_changes?,
          preview_required: preview_required?
        )
      end
      payload
    end

    def detail
      payload = summary.merge(
        guardrails: {
          editable: false,
          source: "Household CFO system",
          rules: GUARDRAILS
        },
        versions: persona.versions.includes(:published_by_user, :source_version).order(version_number: :desc).map { |version| serialize_version(version, include_source: true) },
        assignments: visible_assignments.includes(:cohort, :assigned_by_user, :coach_persona_version).order(created_at: :desc).map { |assignment| serialize_assignment(assignment) }
      )
      if private_configuration_visible?
        payload[:draft] = persona.draft_config
        payload[:phrase_artifact_access] = phrase_artifact_access
        payload[:preview] = serialize_preview
        payload[:content_packs] = persona.draft_content_pack_links.includes(coach_content_pack_version: :coach_content_pack).order(:position).map do |link|
          serialize_content_pack_version(link.coach_content_pack_version)
        end
      end
      payload
    end

    def serialize_content_pack_version(version)
      {
        id: version.id,
        pack_id: version.coach_content_pack_id,
        name: version.name,
        description: version.description.to_s,
        scope: version.scope,
        pack_kind: version.pack_kind,
        version: version.version_number,
        digest: version.content_digest,
        published_at: version.created_at
      }
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
          name: assignment.coach_persona_version.config.dig("identity", "assistant_name") || persona.name
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
        content_manifest_digest: version.content_manifest_digest,
        publication_digest: version.publication_digest,
        published_at: version.created_at,
        published_by: serialize_user(version.published_by_user)
      }
      payload[:config] = version.config if include_config
      if include_source
        payload[:restored_from_version] = version.source_version && {
          id: version.source_version.id,
          number: version.source_version.version_number
        }
        payload[:content_packs] = version.content_pack_links.includes(coach_content_pack_version: :coach_content_pack).order(:position).map do |link|
          serialize_content_pack_version(link.coach_content_pack_version)
        end
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
      return true unless persona.current_published_version.content_manifest_valid?

      persona.current_published_version.config_digest != PersonaSchema.digest(persona.draft_config) ||
        persona.current_published_version.content_manifest_digest != persona.draft_content_manifest_digest
    end

    def preview_required?
      return true if persona.preview_digest.blank? || persona.previewed_draft_revision != persona.draft_revision

      persona.preview_digest != PersonaPromptBuilder.digest(
        persona.draft_config,
        draft_revision: persona.draft_revision,
        content_digests: persona.draft_content_manifest_entries
      )
    end

    def serialize_preview
      return nil if persona.preview_digest.blank?

      {
        digest: persona.preview_digest,
        draft_revision: persona.previewed_draft_revision,
        generated_at: persona.previewed_at
      }
    end

    def phrase_artifact_access
      can_manage = policy.can_manage_phrase_artifacts?(persona)
      {
        can_add: can_manage,
        artifacts: Array(persona.draft_config["phrases"]).map do |phrase|
          participant_supplied = phrase["provenance"] == "participant_supplied"
          can_edit = can_manage && !participant_supplied
          {
            artifact_id: phrase["artifact_id"],
            provenance: phrase["provenance"],
            source_role_at_capture: phrase["source_role_at_capture"],
            source_label: participant_supplied ? "Participant supplied" : "Coach authored",
            can_edit: can_edit,
            can_move: can_manage,
            can_remove: can_manage,
            locked: !can_edit,
            locked_reason: phrase_locked_reason(participant_supplied:, can_manage:)
          }
        end
      }
    end

    def phrase_locked_reason(participant_supplied:, can_manage:)
      return "Participant-supplied wording is sealed and cannot be edited." if participant_supplied
      "Select a coach workspace where you have edit access to change this sealed phrase." unless can_manage
    end

    def permissions
      editable = policy.can_edit?(persona)
      {
        read: true,
        edit: editable && !persona.archived?,
        publish: policy.can_publish?(persona) && !persona.archived?,
        assign: policy.can_assign?(persona),
        archive: editable && !persona.archived? && !persona.live_cohort_assignments?,
        restore: editable && persona.archived?
      }
    end

    def private_configuration_visible?
      @private_configuration_visible = policy.can_view_private_configuration?(persona) unless defined?(@private_configuration_visible)
      @private_configuration_visible
    end

    def display_config
      return persona.draft_config if private_configuration_visible?

      persona.current_published_version&.config.to_h
    end

    def visible_assignments
      @visible_assignments ||= persona.cohort_persona_assignments.where(cohort_id: policy.manageable_cohorts.select(:id))
    end

    def serialize_user(user)
      return nil unless user

      return { full_name: user.full_name } unless private_configuration_visible?

      { id: user.id, email: user.email, full_name: user.full_name }
    end
  end
end
