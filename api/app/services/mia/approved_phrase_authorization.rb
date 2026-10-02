# frozen_string_literal: true

module Mia
  class ApprovedPhraseAuthorization
    Result = Data.define(:actor, :workspace)

    def self.lock!(actor_id:, workspace_id:, permission:)
      actor = User.lock.find_by(id: actor_id)
      workspace = CoachWorkspace.find_by(id: workspace_id)
      return unless actor&.staff? && workspace

      CoachWorkspaceMembership.where(coach_workspace_id: workspace.id, user_id: actor.id).lock.load
      return unless workspace.allows?(actor, permission)

      Result.new(actor:, workspace:)
    end
  end
end
