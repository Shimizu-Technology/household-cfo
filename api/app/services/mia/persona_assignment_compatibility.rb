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

      def ensure_participant_can_join!(cohort_ids:, visible_workspace_id: nil)
        groups = Cohort.where(id: cohort_ids, status: RELEVANT_COHORT_STATUSES)
          .includes(:cohort_persona_assignment, cohort_experience_configuration: :current_published_version).order(:id).to_a
        personas = groups.map do |group|
          assignment = group.cohort_persona_assignment
          [ assignment&.coach_persona_id, assignment&.coach_persona_version_id ]
        end
        tools = groups.map do |group|
          configuration = group.cohort_experience_configuration
          # Include the saved draft: otherwise an intended savings group can
          # accept a household participant until its tools are published.
          configuration&.draft_config
        end
        published_ids = groups.map { |group| group.cohort_experience_configuration&.current_published_version_id }
        return if personas.uniq.length <= 1 && tools.uniq.length <= 1 && published_ids.uniq.length <= 1

        names = groups.map do |group|
          visible_workspace_id.nil? || group.coach_workspace_id == visible_workspace_id ? "“#{group.name}”" : "a group in another program"
        end.uniq.to_sentence
        raise Conflict, "This person cannot join #{names} together because the groups use different assistants or participant tools. Keep them in one group. Remove the extra membership in Participant access before trying again."
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
