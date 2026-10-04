# frozen_string_literal: true

module CoachWorkspaces
  class ParticipantRosterPolicy
    def initialize(user:, workspace:)
      @user = user
      @workspace = workspace
    end

    def manage?
      return true if user&.admin?
      return false unless user&.coach? && workspace

      workspace.allows?(user, :manage_members) || legacy_cohort_manager?
    end

    def cohort_ids
      return [] unless manage?

      cohorts = workspace ? workspace.cohorts : Cohort.all
      return cohorts.pluck(:id) if user.admin? || workspace.allows?(user, :manage_members)

      cohorts.where(id: user.cohort_memberships.where(role: "coach").select(:cohort_id)).pluck(:id)
    end

    private

    attr_reader :user, :workspace

    def legacy_cohort_manager?
      membership = workspace.membership_for(user)
      # Cohort provisioning predates explicit collaborator roles. Preserve only
      # that automatically managed access; any explicit role takes precedence.
      membership&.role == "editor" && membership.cohort_managed? &&
        user.cohort_memberships.joins(:cohort).where(
          role: "coach", cohorts: { coach_workspace_id: workspace.id }
        ).exists?
    end
  end
end
