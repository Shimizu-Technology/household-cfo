# frozen_string_literal: true

module CoachWorkspaces
  # All program mutations lock workspace, users in ID order, then child records.
  # Resolve subjects after locking the workspace so collaborator changes cannot
  # swap the target between authorization and its user lock.
  class MutationAuthority
    def initialize(workspace:, actor:, permissions:, subject_ids: nil)
      @workspace = workspace
      @actor = actor
      @permissions = Array(permissions)
      @subject_ids = subject_ids
    end

    def call
      @workspace.with_lock do
        ids = Array(@subject_ids&.call).push(@actor&.id).compact.uniq.sort
        users = User.where(id: ids).order(:id).lock.index_by(&:id)
        persisted_actor = users[@actor&.id]
        unless persisted_actor&.staff? && persisted_actor.invitation_accepted? && !persisted_actor.revoked?
          raise ActiveRecord::RecordNotFound
        end

        role = CoachWorkspaceMembership.where(coach_workspace_id: @workspace.id, user_id: persisted_actor.id).pick(:role)
        allowed = CoachWorkspace::PERMISSIONS.fetch(role, [])
        unless persisted_actor.admin? || @permissions.any? { |permission| allowed.include?(permission) }
          raise ActiveRecord::RecordNotFound
        end

        yield persisted_actor, users
      end
    end
  end
end
