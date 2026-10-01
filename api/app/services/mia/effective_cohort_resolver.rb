# frozen_string_literal: true

module Mia
  class EffectiveCohortResolver
    def initialize(user:, role: nil)
      @user = user
      @role = role
    end

    def call
      return unless user

      membership_for_status("active") || membership_for_status("enrolling") || latest_membership
    end

    private

    attr_reader :user, :role

    def memberships
      relation = user.cohort_memberships.includes(:cohort)
      role ? relation.where(role: role) : relation
    end

    def membership_for_status(status)
      memberships
        .joins(:cohort)
        .where(cohorts: { status: status })
        .order(Arel.sql("cohorts.starts_on DESC NULLS LAST, cohorts.id DESC, cohort_memberships.id DESC"))
        .first
    end

    def latest_membership
      memberships.order(created_at: :desc, id: :desc).first
    end
  end
end
