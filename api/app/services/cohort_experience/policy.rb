# frozen_string_literal: true

module CohortExperience
  class Policy
    def initialize(user, workspace: nil)
      @user = user
      @workspace = workspace
    end

    def visible_cohorts
      return Cohort.all if user.admin? && workspace.nil?
      return Cohort.none unless workspace&.allows?(user, :view)

      Cohort.where(coach_workspace: workspace)
    end

    def editable_cohorts
      return Cohort.all if user.admin? && workspace.nil?
      return Cohort.none unless workspace&.allows?(user, :edit)

      visible_cohorts
    end

    def reviewable_cohorts
      return Cohort.all if user.admin? && workspace.nil?
      return Cohort.none unless workspace && (workspace.allows?(user, :edit) || workspace.allows?(user, :review))

      visible_cohorts
    end

    def publishable_cohorts
      return Cohort.all if user.admin? && workspace.nil?
      return Cohort.none unless workspace&.allows?(user, :publish)

      visible_cohorts
    end

    alias_method :manageable_cohorts, :visible_cohorts

    private

    attr_reader :user, :workspace
  end
end
