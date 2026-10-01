# frozen_string_literal: true

module Mia
  class PersonaResolver
    ASSIGNABLE_COHORT_STATUSES = %w[active enrolling].freeze

    def initialize(user:, cohort_membership:)
      @user = user
      @cohort_membership = cohort_membership
    end

    def call
      return Persona.neutral unless cohort_membership
      return fallback_for_ambiguous_assignments if conflicting_persona_assignments?

      assignment = cohort_membership.cohort.cohort_persona_assignment
      return Persona.neutral unless assignment

      persona = assignment.coach_persona
      version = assignment.coach_persona_version
      return invalid_assignment_fallback(assignment) unless persona.current_published_version_id == version.id

      RuntimePersona.new(version, participant_id: audience_participant_id)
    rescue PersonaSchema::InvalidConfiguration, ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Mia::PersonaResolver] using fallback: #{error.class}: #{error.message}")
      Persona.neutral
    end

    private

    attr_reader :user, :cohort_membership

    def audience_participant_id
      return unless user && cohort_membership
      return unless cohort_membership.user_id == user.id && cohort_membership.role == "participant"

      user.id
    end

    def conflicting_persona_assignments?
      return false unless user

      relevant_memberships = user.cohort_memberships
        .joins(cohort: :cohort_persona_assignment)
        .where(cohorts: { status: ASSIGNABLE_COHORT_STATUSES })
      relevant_memberships
        .distinct
        .count("cohort_persona_assignments.coach_persona_id") > 1
    end

    def fallback_for_ambiguous_assignments
      Rails.logger.error("[Mia::PersonaResolver] conflicting persona assignments user_id=#{user&.id}")
      Persona.neutral
    end

    def invalid_assignment_fallback(assignment)
      Rails.logger.error(
        "[Mia::PersonaResolver] stale persona assignment assignment_id=#{assignment.id} " \
        "version_id=#{assignment.coach_persona_version_id}"
      )
      Persona.neutral
    end
  end
end
