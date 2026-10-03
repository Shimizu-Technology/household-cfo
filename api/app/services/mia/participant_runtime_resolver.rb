# frozen_string_literal: true

module Mia
  class ParticipantRuntimeResolver
    def initialize(user:, cohort_membership: nil, coach_workspace: nil)
      @user = user
      @provided_membership = cohort_membership
      @coach_workspace = coach_workspace
    end

    def call
      return standalone_runtime unless user

      resolve_in_transaction do
        membership = resolved_membership
        next standalone_runtime unless membership

        exposure = latest_exposure_for(membership)
        release = exposure&.cohort_release || membership.cohort.active_cohort_release
        next legacy_runtime(membership) unless release

        released_runtime(membership, release, exposure)
      end
    rescue StandardError => error
      Rails.logger.error("[Mia::ParticipantRuntimeResolver] safe fallback user_id=#{user&.id} error=#{error.class}")
      membership = safe_membership
      safe_runtime(membership, source: "safe_fallback")
    end

    private

    attr_reader :user, :provided_membership, :coach_workspace

    def resolve_in_transaction(&block)
      if ApplicationRecord.connection.transaction_open?
        ApplicationRecord.transaction(requires_new: true, &block)
      else
        ApplicationRecord.transaction(isolation: :repeatable_read, requires_new: true, &block)
      end
    end

    def resolved_membership
      membership = if coach_workspace
        provided_membership
      else
        provided_membership || EffectiveCohortResolver.new(user: user, role: "participant").call
      end
      return unless membership

      relation = CohortMembership.includes(cohort: :active_cohort_release)
      relation = relation.joins(:cohort).where(cohorts: { coach_workspace_id: coach_workspace.id }) if coach_workspace
      relation.find_by(
        id: membership.id,
        user_id: user.id,
        role: "participant"
      )
    end

    def safe_membership
      resolved_membership
    rescue StandardError
      nil
    end

    def latest_exposure_for(membership)
      CohortReleaseExposure.includes(:cohort_release)
        .where(
          cohort_id: membership.cohort_id,
          user_id: membership.user_id,
          cohort_membership_id: membership.id,
          membership_started_at: membership.created_at
        )
        .order(id: :desc)
        .first
    end

    def released_runtime(membership, release, exposure)
      unless release.cohort_id == membership.cohort_id && release.coach_workspace_id == membership.cohort.coach_workspace_id
        raise ActiveRecord::RecordNotFound, "release crossed its cohort boundary"
      end
      unless CohortReleases::RuntimeIntegrityCache.valid_runtime?(release)
        return safe_runtime(membership, source: "safe_fallback")
      end

      persona = if release.persona_mode == "published_version"
        RuntimePersona.for_release(
          version: release.coach_persona_version,
          user: user,
          cohort_membership: membership,
          release: release
        )
      else
        Persona.neutral
      end
      capabilities = CohortExperience::EffectiveCapabilitiesResolver.for_release(
        release: release,
        cohort_membership: membership
      )
      ParticipantRuntime.new(
        membership: membership,
        cohort: membership.cohort,
        release: release,
        persona: persona,
        capabilities: capabilities,
        source: exposure ? "participant_exposure" : "cohort_active_release",
        exposure: exposure
      )
    rescue PersonaSchema::InvalidConfiguration, KeyError, ArgumentError, ActiveRecord::RecordNotFound => error
      Rails.logger.error(
        "[Mia::ParticipantRuntimeResolver] corrupt release release_id=#{release&.id} user_id=#{user&.id} error=#{error.class}"
      )
      safe_runtime(membership, source: "safe_fallback")
    end

    def legacy_runtime(membership)
      persona = PersonaResolver.new(user: user, cohort_membership: membership).call
      capabilities = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: membership).call
      ParticipantRuntime.new(
        membership: membership,
        cohort: membership.cohort,
        release: nil,
        persona: persona,
        capabilities: capabilities,
        source: "legacy_fallback"
      )
    end

    def standalone_runtime
      ParticipantRuntime.new(
        membership: nil,
        cohort: nil,
        release: nil,
        persona: PersonaResolver.new(user: user, cohort_membership: nil).call,
        capabilities: CohortExperience::EffectiveCapabilitiesResolver.safe_default_payload(
          cohort_membership: nil,
          standalone: true
        ),
        source: "standalone_default"
      )
    rescue StandardError
      safe_runtime(nil, source: "standalone_default", standalone: true)
    end

    def safe_runtime(membership, source:, standalone: false)
      ParticipantRuntime.new(
        membership: membership,
        cohort: membership&.cohort,
        release: nil,
        persona: Persona.neutral,
        capabilities: CohortExperience::EffectiveCapabilitiesResolver.safe_default_payload(
          cohort_membership: membership,
          standalone: standalone
        ),
        source: source
      )
    end
  end
end
