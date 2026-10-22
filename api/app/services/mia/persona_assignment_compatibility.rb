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
          .includes(:cohort_persona_assignment, :cohort_experience_configuration).order(:id).to_a
        # Same rule as before for the assistant: one coaching persona. Versions may
        # differ between groups; a release reconciles them later.
        personas = groups.filter_map { |group| group.cohort_persona_assignment&.coach_persona_id }.uniq
        # Tools follow the release-time rule: groups must share the same published
        # tools version (a published group and an unprepared one differ). The saved
        # draft also states the intended experience, so an unpublished savings group
        # can't hide beside a household one; no setting means Household CFO.
        published = groups.map { |group| group.cohort_experience_configuration&.current_published_version_id }.uniq
        modes = groups.map { |group| experience_mode(group) }.uniq
        return if personas.length <= 1 && published.length <= 1 && modes.length <= 1

        names = groups.map do |group|
          visible_workspace_id.nil? || group.coach_workspace_id == visible_workspace_id ? "“#{group.name}”" : "a group in another program"
        end.uniq.to_sentence
        raise Conflict, "This person cannot join #{names} together because the groups use different assistants or participant tools. Keep them in one group. Remove the extra membership in Participant access before trying again."
      end

      private

      def experience_mode(group)
        config = group.cohort_experience_configuration&.draft_config || {}
        config["experience_mode"].presence || "household_cfo"
      end

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
