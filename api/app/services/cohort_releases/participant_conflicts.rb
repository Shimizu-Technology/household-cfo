# frozen_string_literal: true

module CohortReleases
  # Keep the release-time safety check, including configurations changed after
  # someone joined. Report people and remedies rather than an unexplained count.
  class ParticipantConflicts
    def initialize(cohort:)
      @cohort = cohort
    end

    def entries
      @entries ||= begin
        participant_ids = @cohort.cohort_memberships.where(role: "participant")
          .joins(:user).where(users: { invitation_status: "accepted" }).select(:user_id)
        memberships = CohortMembership.includes(:user, cohort: %i[cohort_persona_assignment cohort_experience_configuration])
          .joins(:cohort).where(user_id: participant_ids, role: "participant",
            cohorts: { status: Mia::PersonaResolver::ASSIGNABLE_COHORT_STATUSES })
        selections = {}
        memberships.group_by(&:user_id).values.select do |rows|
          rows.map do |row|
            _, persona, version = (selections[row.cohort_id] ||= Mia::PersonaResolver.selection_for(row.cohort))
            [ persona&.id, version&.id,
              row.cohort.cohort_experience_configuration&.current_published_version_id ]
          end.uniq.length > 1
        end
      end
    end

    def messages
      entries.map do |rows|
        person = rows.first.user
        groups = rows.map do |row|
          row.cohort.coach_workspace_id == @cohort.coach_workspace_id ? "“#{row.cohort.name}”" : "a group in another program"
        end.uniq.to_sentence
        "#{person.full_name} (#{person.email}) has different assistant or tools settings in #{groups}. Remove them from the extra group in Participant access before preparing this version."
      end
    end
  end
end
