# frozen_string_literal: true

module Mia
  class PersonaStudioPolicy
    def initialize(user, workspace: nil)
      @user = user
      @workspace = workspace
    end

    def visible_personas
      return CoachPersona.all if global_admin?
      return CoachPersona.none unless workspace&.allows?(user, :view)

      CoachPersona.where(coach_workspace: workspace)
    end

    def editable_personas
      return CoachPersona.all if global_admin?
      return CoachPersona.none unless workspace&.allows?(user, :edit)

      visible_personas
    end

    def publishable_personas
      return CoachPersona.all if global_admin?
      return CoachPersona.none unless workspace&.allows?(user, :publish)

      visible_personas
    end

    def assignable_personas
      return CoachPersona.all if global_admin?
      return CoachPersona.none unless workspace&.allows?(user, :assign)

      visible_personas
    end

    def manageable_cohorts
      return Cohort.all if global_admin?
      return Cohort.none unless workspace&.allows?(user, :view)

      Cohort.where(coach_workspace: workspace)
    end

    def assignment_manageable_cohorts
      return Cohort.all if global_admin?
      return Cohort.none unless workspace&.allows?(user, :assign)

      manageable_cohorts
    end

    def can_edit?(persona)
      editable_personas.where(id: persona.id).exists?
    end

    def can_view_private_configuration?(persona)
      global_admin? || (workspace.present? && persona.coach_workspace_id == workspace.id && workspace.allows?(user, :view))
    end

    def can_assign?(persona)
      assignable_personas.where(id: persona.id).exists? && persona.published? && !persona.archived?
    end

    def can_manage_phrase_artifacts?(persona)
      # A platform administrator must select the workspace explicitly before
      # changing its sealed coach-authored language. Editors and owners in that
      # workspace may collaborate while every edit keeps its actor provenance.
      return false if global_admin?

      can_edit?(persona) && !persona.archived?
    end

    def can_publish?(persona)
      publishable_personas.where(id: persona.id).exists?
    end

    private

    attr_reader :user, :workspace

    def global_admin?
      user.admin? && workspace.nil?
    end
  end
end
