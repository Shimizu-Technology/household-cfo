# frozen_string_literal: true

# A preview seat lets a coach or admin use the app as a member of a group: that
# group's voice, tools and branding, and its savings challenge, on their own
# household. It is a cohort membership with the role "preview", so the program
# never counts it (see CohortMembership and SavingsEnrollment.counted).
module PreviewSeats
  LEFT_MESSAGE = "You left this group's preview. Your own household is unchanged."
  LEFT_CHALLENGE_MESSAGE = "You left this group's preview and your challenge preview ended. " \
    "It can't be restarted. Your own household is unchanged.".freeze

  # Admins may use any group; a coach, the groups of their coach workspaces.
  def self.visible_cohorts(user)
    return Cohort.none unless user&.staff? && !user.revoked?

    scope = user.admin? ? Cohort.all : Cohort.where(coach_workspace_id: user.coach_workspace_memberships.select(:coach_workspace_id))
    scope.where.not(status: "archived")
  end

  # What /auth/me shows: every group the person may preview, and whether they
  # already hold a seat in it.
  def self.groups_for(user)
    cohorts = visible_cohorts(user).includes(:coach_workspace).order(:name, :id).to_a
    return [] if cohorts.empty?

    seated = user.preview_seats.where(cohort_id: cohorts.map(&:id)).pluck(:cohort_id).to_set
    enrolled = SavingsEnrollment.previews.where(user_id: user.id, cohort_id: cohorts.map(&:id), status: %w[active completed]).pluck(:cohort_id).to_set
    cohorts.map do |cohort|
      { cohort_id: cohort.id, name: cohort.name, status: cohort.status, program_name: cohort.coach_workspace.name,
        seated: seated.include?(cohort.id), challenge: cohort.savings_challenge_enabled, challenge_joined: enrolled.include?(cohort.id) }
    end
  end

  def self.join!(user:, cohort_id:)
    cohort = visible_cohorts(user).find(cohort_id)
    CohortMembership.previews.find_by(cohort: cohort, user: user) ||
      CohortMembership.create!(cohort: cohort, user: user, role: CohortMembership::PREVIEW_ROLE)
  rescue ActiveRecord::RecordNotUnique
    CohortMembership.previews.find_by!(cohort_id: cohort_id, user: user)
  end

  # Ends the seat. An open challenge preview ends as a withdrawal under the same
  # household lock the participant tools take, so nothing writes to it mid-leave.
  # Returns the plain confirmation to show.
  def self.leave!(user:, cohort_id:)
    seat = user.preview_seats.find_by(cohort_id: cohort_id)
    return LEFT_MESSAGE unless seat

    household = HouseholdFinance::WorkspaceResolver.new(user).household
    withdrew = false
    household.with_lock do
      enrollment = SavingsEnrollment.lock.find_by(user_id: user.id, cohort_id: cohort_id, accepted_cohort_membership_id: seat.id)
      if enrollment&.status == "active"
        enrollment.update!(status: "withdrawn")
        withdrew = true
      end
      seat.destroy!
    end
    withdrew ? LEFT_CHALLENGE_MESSAGE : LEFT_MESSAGE
  end

  # A person who stops being staff keeps no seats.
  def self.release_all!(user)
    user.preview_seats.pluck(:cohort_id).each { |cohort_id| leave!(user: user, cohort_id: cohort_id) }
  end
end
