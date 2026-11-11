# frozen_string_literal: true

# A preview seat lets a coach or admin use the app as a member of a group: that
# group's voice, tools and branding, and its savings challenge, on their own
# household. It is a cohort membership with the role "preview", so the program
# never counts it (see CohortMembership and SavingsEnrollment.counted).
module PreviewSeats
  LEFT_MESSAGE = "You left this group's preview. Your own household is unchanged."
  LEFT_CHALLENGE_MESSAGE = "You left this group's preview and your challenge preview ended. " \
    "Your own household is unchanged.".freeze

  # Admins may use any group; a coach, the groups of their coach workspaces.
  def self.visible_cohorts(user)
    return Cohort.none unless user&.staff? && !user.revoked?

    scope = user.admin? ? Cohort.all : Cohort.where(coach_workspace_id: user.coach_workspace_memberships.select(:coach_workspace_id))
    scope.where.not(status: "archived")
  end

  # What /auth/me shows: every group the person may preview, and whether they
  # already hold a seat in it. A seat they still hold in a group they may no longer
  # preview is listed too (`available: false`), so it can always be left.
  def self.groups_for(user)
    cohorts = visible_cohorts(user).includes(:coach_workspace).order(:name, :id).to_a
    held = user.preview_seats.includes(cohort: :coach_workspace).to_a
    gone = held.reject { |seat| cohorts.any? { |cohort| cohort.id == seat.cohort_id } }.map(&:cohort).sort_by { |cohort| [ cohort.name, cohort.id ] }
    return [] if cohorts.empty? && gone.empty?

    ids = (cohorts + gone).map(&:id)
    seated = held.map(&:cohort_id).to_set
    enrolled = SavingsEnrollment.previews.where(user_id: user.id, cohort_id: ids, status: %w[active completed]).pluck(:cohort_id).to_set
    (cohorts.map { |cohort| [ cohort, true ] } + gone.map { |cohort| [ cohort, false ] }).map do |cohort, available|
      { cohort_id: cohort.id, name: cohort.name, status: cohort.status, program_name: cohort.coach_workspace.name,
        seated: seated.include?(cohort.id), available: available, challenge: cohort.savings_challenge_enabled,
        challenge_joined: enrolled.include?(cohort.id) }
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
      seat.end_preview!
    end
    withdrew ? LEFT_CHALLENGE_MESSAGE : LEFT_MESSAGE
  end

  # A person who stops being staff keeps no seats. Ending a seat is bookkeeping: it
  # can never stand in the way of the change that caused it (see `release_safely`).
  def self.release_all!(user)
    user.preview_seats.pluck(:cohort_id).each { |cohort_id| release_safely(user, cohort_id) }
  end

  # Ends the seats a person may no longer use: after they leave a coach workspace,
  # change role or are revoked. (Every reader already ignores such a seat; this
  # also withdraws an open challenge preview and frees the row.)
  def self.release_unavailable!(user)
    keep = visible_cohorts(user).pluck(:id)
    user.preview_seats.where.not(cohort_id: keep).pluck(:cohort_id).each { |cohort_id| release_safely(user, cohort_id) }
  end

  # A group that is archived keeps no preview seats.
  def self.release_cohort!(cohort)
    cohort.preview_seats.includes(:user).to_a.each { |seat| release_safely(seat.user, cohort.id) }
  end

  # Losing access (revoking, demoting, archiving, removing from a workspace) must
  # never fail because a seat could not be tidied up: the readers already ignore a
  # seat its holder has no right to. A failure inside a savepoint is rolled back
  # on its own, reported, and the change that called us goes ahead.
  def self.release_safely(user, cohort_id)
    ActiveRecord::Base.transaction(requires_new: true) { leave!(user: user, cohort_id: cohort_id) }
  rescue StandardError => e
    Rails.error.report(e, handled: true, severity: :error,
      context: { preview_seat_release: true, user_id: user&.id, cohort_id: cohort_id })
    if defined?(Sentry) && Sentry.initialized?
      Sentry.capture_exception(e, tags: { preview_seat_release: "failed" }, extra: { user_id: user&.id, cohort_id: cohort_id })
    end
    Rails.logger.error("[PreviewSeats] could not end the seat of user #{user&.id} in cohort #{cohort_id}: #{e.class}: #{e.message}")
    nil
  end
end
