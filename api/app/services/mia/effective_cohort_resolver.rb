# frozen_string_literal: true

module Mia
  class EffectiveCohortResolver
    class InvalidSelection < StandardError; end

    def initialize(user:, role: nil, requested_cohort_id: nil, coach_workspace: nil)
      @user = user
      @role = role
      @requested_cohort_id = requested_cohort_id.to_s.strip.presence
      @coach_workspace = coach_workspace
    end

    def call
      return unless user

      membership = if requested_cohort_id
        requested_membership
      else
        membership_for_status("active") || membership_for_status("enrolling") || latest_membership
      end
      return membership if membership || coach_workspace.nil? || user.staff?

      raise InvalidSelection, "This coaching program link is unavailable."
    end

    private

    attr_reader :user, :role, :requested_cohort_id, :coach_workspace

    def requested_membership
      id = Integer(requested_cohort_id, 10)
      membership = memberships.find_by(cohort_id: id)
      return membership if membership

      raise InvalidSelection, "The selected cohort is unavailable for this participant."
    rescue ArgumentError
      raise InvalidSelection, "The selected cohort is invalid."
    end

    def memberships
      relation = user.cohort_memberships.includes(:cohort)
      relation = relation.where(role: role) if role
      relation = relation.joins(:cohort).where(cohorts: { coach_workspace_id: coach_workspace.id }) if coach_workspace
      relation
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
