# frozen_string_literal: true

module CohortReleases
  class Authorization
    class NotAuthorized < StandardError; end

    def initialize(cohort:, actor:)
      @cohort = cohort
      @actor = actor
    end

    def call!
      persisted_actor = User.lock.find_by(id: actor&.id)
      raise NotAuthorized, "Only a workspace owner or reviewer can seal a cohort release" unless persisted_actor

      return [ persisted_actor, "platform_admin" ] if persisted_actor.admin?

      membership = CoachWorkspaceMembership.lock.find_by(
        coach_workspace_id: cohort.coach_workspace_id,
        user_id: persisted_actor.id
      )
      permissions = CoachWorkspace::PERMISSIONS.fetch(membership&.role, [])
      unless permissions.include?(:publish) && permissions.include?(:assign)
        raise NotAuthorized, "Only a workspace owner or reviewer can seal a cohort release"
      end

      [ persisted_actor, membership.role ]
    end

    private

    attr_reader :cohort, :actor
  end
end
