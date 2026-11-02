# frozen_string_literal: true

module Mia
  class PersonaResolver
    ASSIGNABLE_COHORT_STATUSES = %w[active enrolling].freeze

    # A program default is unambiguous only when exactly one active voice is
    # published. An explicit (even invalid) assignment always takes precedence.
    def self.selection_for(cohort)
      assignment = cohort.cohort_persona_assignment
      return [ assignment, assignment.coach_persona, assignment.coach_persona_version ] if assignment

      personas = CoachPersona.active.where(coach_workspace_id: cohort.coach_workspace_id)
        .where.not(current_published_version_id: nil).includes(:current_published_version).limit(2).to_a
      persona = personas.sole if personas.one?
      [ nil, persona, persona&.current_published_version ]
    end

    def self.valid_selection?(cohort, persona, version)
      persona && version && !persona.archived? && persona.coach_workspace_id == cohort.coach_workspace_id &&
        version.coach_persona_id == persona.id && persona.current_published_version_id == version.id
    end

    def initialize(user:, cohort_membership:)
      @user = user
      @cohort_membership = cohort_membership
    end

    def call
      return Persona.neutral unless cohort_membership
      return fallback_for_ambiguous_assignments if conflicting_persona_assignments?

      cohort = cohort_membership.cohort
      assignment, persona, version = self.class.selection_for(cohort)
      return Persona.neutral unless persona
      return invalid_assignment_fallback(assignment) unless self.class.valid_selection?(cohort, persona, version)

      RuntimePersona.for_participant(
        version: version,
        user: user,
        cohort_membership: cohort_membership
      )
    rescue PersonaSchema::InvalidConfiguration, ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Mia::PersonaResolver] using fallback: #{error.class}: #{error.message}")
      Persona.neutral
    end

    private

    attr_reader :user, :cohort_membership

    def conflicting_persona_assignments?
      return false unless user

      cohorts = user.cohort_memberships.where(role: "participant")
        .joins(:cohort)
        .where(cohorts: { status: ASSIGNABLE_COHORT_STATUSES })
        .pluck("cohorts.id", "cohorts.coach_workspace_id")
      assignments = CohortPersonaAssignment.where(cohort_id: cohorts.map(&:first))
        .pluck(:cohort_id, :coach_persona_id).to_h
      published = CoachPersona.active.where(coach_workspace_id: cohorts.map(&:last).uniq)
        .where.not(current_published_version_id: nil).pluck(:coach_workspace_id, :id)
        .group_by(&:first)
      cohorts.filter_map do |cohort_id, workspace_id|
        next assignments.fetch(cohort_id) if assignments.key?(cohort_id)

        voices = published.fetch(workspace_id, [])
        voices.first.last if voices.one?
      end.uniq.length > 1
    end

    def fallback_for_ambiguous_assignments
      Rails.logger.error("[Mia::PersonaResolver] conflicting persona assignments user_id=#{user&.id}")
      Persona.neutral
    end

    def invalid_assignment_fallback(assignment)
      Rails.logger.error(
        "[Mia::PersonaResolver] invalid persona selection assignment_id=#{assignment&.id}"
      )
      Persona.neutral
    end
  end
end
