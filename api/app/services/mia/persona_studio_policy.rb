# frozen_string_literal: true

module Mia
  class PersonaStudioPolicy
    def initialize(user)
      @user = user
    end

    def visible_personas
      return CoachPersona.all if user.admin?

      owned = CoachPersona.where(created_by_user_id: user.id)
      assigned = CoachPersona.where(
        id: CohortPersonaAssignment.where(cohort_id: manageable_cohorts.select(:id)).select(:coach_persona_id)
      )
      owned.or(assigned).distinct
    end

    def editable_personas
      return CoachPersona.all if user.admin?

      CoachPersona.where(created_by_user_id: user.id).where.not(id: personas_assigned_outside_scope)
    end

    def manageable_cohorts
      return Cohort.all if user.admin?

      Cohort.joins(:cohort_memberships)
        .where(cohort_memberships: { user_id: user.id, role: "coach" })
        .distinct
    end

    def can_edit?(persona)
      editable_personas.where(id: persona.id).exists?
    end

    def can_view_private_configuration?(persona)
      user.admin? || persona.created_by_user_id == user.id
    end

    def can_assign?(persona)
      can_edit?(persona) && persona.published? && !persona.archived?
    end

    def can_manage_phrase_artifacts?(persona)
      persona.created_by_user_id == user.id && !persona.archived?
    end

    private

    attr_reader :user

    def personas_assigned_outside_scope
      CohortPersonaAssignment
        .where.not(cohort_id: manageable_cohorts.select(:id))
        .select(:coach_persona_id)
    end
  end
end
