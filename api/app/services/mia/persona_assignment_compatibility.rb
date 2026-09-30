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
      def participant_ids_for(cohort:)
        cohort.cohort_memberships.where(role: "participant").distinct.order(:user_id).pluck(:user_id)
      end

      def lock_participants!(user_ids:)
        ids = Array(user_ids).map(&:to_i).uniq.sort
        User.where(id: ids).order(:id).lock.load if ids.any?
      end

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
        participant_ids = participant_ids_for(cohort: cohort)
        return [] if participant_ids.empty?

        participant_count = CohortPersonaAssignment
          .joins(cohort: :cohort_memberships)
          .where(cohort_memberships: { role: "participant", user_id: participant_ids })
          .where(cohorts: { status: RELEVANT_COHORT_STATUSES })
          .where.not(cohort_id: cohort.id)
          .where.not(coach_persona_id: persona.id)
          .distinct
          .count("cohort_memberships.user_id")
        return [] if participant_count.zero?

        [ { participant_count: participant_count } ]
      end
    end
  end
end
