# frozen_string_literal: true

module Mia
  class PersonaAssignmentCompatibility
    RELEVANT_COHORT_STATUSES = %w[draft enrolling active].freeze

    class Conflict < StandardError
      attr_reader :conflicts

      def initialize(message, conflicts: [])
        @conflicts = conflicts
        super(message)
      end
    end

    class << self
      def ensure_cohort_can_use!(cohort:, persona:)
        conflicts = conflicting_cohorts(cohort: cohort, persona: persona)
        return if conflicts.empty?

        raise Conflict.new(
          "Some participants already use a different persona through another cohort.",
          conflicts: conflicts
        )
      end

      def ensure_participant_can_join!(cohort_ids:)
        persona_ids = CohortPersonaAssignment
          .joins(:cohort)
          .where(cohort_id: cohort_ids, cohorts: { status: RELEVANT_COHORT_STATUSES })
          .distinct
          .pluck(:coach_persona_id)
        return if persona_ids.length <= 1

        raise Conflict, "This participant would receive different personas from their cohorts."
      end

      private

      def conflicting_cohorts(cohort:, persona:)
        participant_ids = cohort.cohort_memberships.where(role: "participant").select(:user_id)
        counts = CohortPersonaAssignment
          .joins(cohort: :cohort_memberships)
          .where(cohort_memberships: { role: "participant", user_id: participant_ids })
          .where(cohorts: { status: RELEVANT_COHORT_STATUSES })
          .where.not(cohort_id: cohort.id)
          .where.not(coach_persona_id: persona.id)
          .group("cohorts.id", "cohorts.name")
          .distinct
          .count("cohort_memberships.user_id")

        counts.map do |(cohort_id, cohort_name), participant_count|
          {
            cohort_id: cohort_id,
            cohort_name: cohort_name,
            participant_count: participant_count
          }
        end
      end
    end
  end
end
