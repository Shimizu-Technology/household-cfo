# frozen_string_literal: true

module CoachWorkspaces
  # A program's owner coaches the program's groups. Without a cohort coach
  # membership the owner could not see the challenge roster or seal reports
  # (platform admins deliberately never substitute for that), so owners who are
  # coaches are added as coach of each non-archived group in their program.
  # Existing cohort memberships are never changed.
  module OwnerCohortAccess
    module_function

    def for_cohort!(cohort)
      return unless cohort.coach_workspace_id

      owner_coaches(cohort.coach_workspace).each { |user| ensure_coach!(cohort, user) }
    end

    def for_owner!(workspace, user)
      return unless user&.coach?

      workspace.cohorts.where.not(status: "archived").find_each { |cohort| ensure_coach!(cohort, user) }
    end

    def owner_coaches(workspace)
      workspace.coach_workspace_memberships.where(role: "owner").includes(:user).map(&:user).select(&:coach?)
    end

    def ensure_coach!(cohort, user)
      return if CohortMembership.exists?(cohort_id: cohort.id, user_id: user.id)

      CohortMembership.create!(cohort: cohort, user: user, role: "coach")
    end
  end
end
