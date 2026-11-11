# frozen_string_literal: true

# The sections of the Admin side a signed-in person may open. The server decides
# once, here, and /auth/me hands the list to the web, so the client never works
# out roles itself. The same names are the web routes: /admin/<key>.
#
# A section is listed only when its main read would succeed. Each check asks the
# same policy the section's controller asks, so the list cannot promise a screen
# its own API then refuses (api_v1_admin_sections_test checks every role).
module AdminSections
  SECTIONS = [
    { key: "today", label: "Today" },
    { key: "people", label: "People" },
    { key: "groups", label: "Groups" },
    { key: "coaching", label: "Coaching" },
    { key: "reports", label: "Reports" },
    { key: "support", label: "Support" },
    { key: "settings", label: "Settings" }
  ].freeze

  # `workspace` is the coach workspace the person is working in (nil for an
  # administrator who has not picked one, who sees everything).
  def self.for(user, workspace: nil)
    return [] unless user&.staff? && !user.revoked?

    team_cohorts = nil
    program_cohorts = -> { team_cohorts ||= on_team_cohorts(user, workspace) }
    SECTIONS.filter_map do |section|
      section.merge(access: "full") if allowed?(section.fetch(:key), user, workspace, program_cohorts)
    end
  end

  # `staff_allowed?` needs the person on the group's own team (its creator or a coach or
  # admin of it), so only those groups can ever pass. Asking it of just those groups, in
  # one query up front, keeps an editor who coaches nothing from paying per group.
  def self.on_team_cohorts(user, workspace)
    workspace.cohorts.where(created_by_user_id: user.id)
      .or(workspace.cohorts.where(id: CohortMembership.where(user_id: user.id, role: %w[coach admin]).select(:cohort_id)))
      .to_a
  end
  private_class_method :on_team_cohorts

  def self.allowed?(key, user, workspace, program_cohorts)
    return true if user.admin?
    return false unless workspace&.membership_for(user)

    case key
    when "today" then program_cohorts.call.any? { |cohort| ChallengePrivacy::Access.staff_allowed?(cohort, user) }
    # Cohorts, people and Support's inbox all sit behind program management.
    when "people", "support" then CoachWorkspaces::ParticipantRosterPolicy.new(user: user, workspace: workspace).manage?
    when "groups", "settings" then workspace.allows?(user, :manage_members)
    when "coaching" then Mia::PersonaStudioPolicy.new(user, workspace: workspace).can_view?
    when "reports" then program_cohorts.call.any? { |cohort| ChallengePrivacy::Access.staff_allowed?(cohort, user, export: true) }
    else false
    end
  end
  private_class_method :allowed?
end
