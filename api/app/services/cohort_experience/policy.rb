# frozen_string_literal: true

module CohortExperience
  class Policy
    def initialize(user)
      @user = user
    end

    def manageable_cohorts
      return Cohort.all if user.admin?

      Cohort.joins(:cohort_memberships)
        .where(cohort_memberships: { user_id: user.id, role: "coach" })
        .distinct
    end

    private

    attr_reader :user
  end
end
