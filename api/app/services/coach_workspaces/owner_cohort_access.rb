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

    # Undo only the rows granted by ownership; manually assigned coach rows stay.
    def revoke!(workspace, user)
      CohortMembership.transaction do
        lock!(workspace.id, user.id)
        CohortMembership.joins(:cohort)
          .where(user_id: user.id, owner_managed: true, cohorts: { coach_workspace_id: workspace.id })
          .find_each(&:destroy!)
      end
    end

    def owner_coaches(workspace)
      workspace.coach_workspace_memberships.where(role: "owner").includes(:user).map(&:user).select(&:coach?)
    end

    # Takes the same per-(workspace, user) advisory lock the membership
    # reconciliation uses, then re-checks that the user still owns the program,
    # so a concurrent demotion can never leave an owner-managed row behind.
    def ensure_coach!(cohort, user)
      workspace_id = cohort.coach_workspace_id
      CohortMembership.transaction do
        lock!(workspace_id, user.id)
        next unless CoachWorkspaceMembership.exists?(coach_workspace_id: workspace_id, user_id: user.id, role: "owner")
        next if CohortMembership.exists?(cohort_id: cohort.id, user_id: user.id)

        CohortMembership.create!(cohort: cohort, user: user, role: "coach", owner_managed: true)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:user_id, :taken)
    end

    def lock!(workspace_id, user_id)
      CohortMembership.connection.exec_query(
        "SELECT pg_advisory_xact_lock($1, $2)",
        "Owner cohort access lock",
        [
          ActiveRecord::Relation::QueryAttribute.new("coach_workspace_id", workspace_id, ActiveRecord::Type::Integer.new),
          ActiveRecord::Relation::QueryAttribute.new("user_id", user_id, ActiveRecord::Type::Integer.new)
        ]
      )
    end
  end
end
