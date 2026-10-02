# frozen_string_literal: true

module CoachWorkspaces
  class Resolver
    def initialize(user:, requested_id: nil)
      @user = user
      @requested_id = parse_requested_id(requested_id)
    end

    def call
      raise ActiveRecord::RecordNotFound, "Coach workspace not found" unless user&.staff?

      if requested_id
        return CoachWorkspace.visible_to(user).includes(:coach_profile).find(requested_id)
      end

      default_workspace || Provisioner.ensure_for!(user)
    end

    private

    attr_reader :user, :requested_id

    def parse_requested_id(value)
      return nil if value.blank?

      raw_value = value.to_s
      raise ActiveRecord::RecordNotFound, "Coach workspace not found" unless raw_value.match?(/\A[1-9]\d*\z/)

      Integer(raw_value, 10)
    end

    def default_workspace
      if user.admin?
        owned = CoachWorkspace.joins(:coach_workspace_memberships)
          .includes(:coach_profile)
          .find_by(coach_workspace_memberships: { user_id: user.id, role: "owner" })
        return owned if owned

        return nil
      end

      CoachWorkspace.joins(:coach_workspace_memberships)
        .includes(:coach_profile)
        .where(coach_workspace_memberships: { user_id: user.id })
        .order(Arel.sql("CASE coach_workspace_memberships.role WHEN 'owner' THEN 0 WHEN 'editor' THEN 1 WHEN 'reviewer' THEN 2 ELSE 3 END"), :id)
        .first
    end
  end
end
