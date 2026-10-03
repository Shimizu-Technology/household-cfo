# frozen_string_literal: true

module CoachWorkspaces
  class Provisioner
    def self.ensure_for!(user)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      raise ArgumentError, "Only coaches and administrators can own a coach workspace" unless user&.staff?

      user.with_lock do
        existing = user.coach_workspace_memberships.includes(coach_workspace: :coach_profile)
          .order(Arel.sql("CASE role WHEN 'owner' THEN 0 ELSE 1 END"), :id).first
        return existing.coach_workspace if existing

        workspace = CoachWorkspace.create!(
          name: "#{user.full_name}'s coaching workspace",
          slug: available_slug,
          created_by_user: user
        )
        workspace.coach_workspace_memberships.create!(user: user, role: "owner")
        workspace.create_coach_profile!(
          display_name: public_coach_name,
          title: "Financial coach",
          last_edited_by_user: user
        )
        Branding::Provisioner.ensure_for!(workspace: workspace, actor: user)
        workspace
      end
    end

    private

    attr_reader :user

    def available_slug
      base = "coach-workspace-#{user.id}"
      return base unless CoachWorkspace.exists?(slug: base)

      "#{base}-#{SecureRandom.hex(4)}"
    end

    def public_coach_name
      [ user.first_name, user.last_name ].compact_blank.join(" ").presence || "your coach"
    end
  end
end
