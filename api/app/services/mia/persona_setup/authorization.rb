# frozen_string_literal: true

module Mia
  module PersonaSetup
    class Authorization
      Result = Data.define(:actor, :workspace, :persona)

      def self.lock_editor!(actor_id:, workspace_id:, persona_id:)
        actor = User.lock.find_by(id: actor_id)
        workspace = CoachWorkspace.find_by(id: workspace_id)
        return unless actor&.staff? && workspace

        CoachWorkspaceMembership.where(coach_workspace_id: workspace.id, user_id: actor.id).lock.load
        persona = CoachPersona.lock.find_by(id: persona_id, coach_workspace_id: workspace.id)
        return unless persona && workspace.allows?(actor, :edit)

        Result.new(actor:, workspace:, persona:)
      end
    end
  end
end
