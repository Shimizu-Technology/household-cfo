# frozen_string_literal: true

module Mia
  class EffectiveCohortResolver
    def initialize(user:)
      @user = user
    end

    def call
      return unless user

      membership_for_status("active") || membership_for_status("enrolling") || latest_membership
    end

    private

    attr_reader :user

    def memberships
      user.cohort_memberships.includes(:cohort)
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
