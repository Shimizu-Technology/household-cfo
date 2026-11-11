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

    SECTIONS.filter_map do |section|
      section.merge(access: "full") if allowed?(section.fetch(:key), user, workspace)
    end
  end

  def self.allowed?(key, user, workspace)
    return true if user.admin?
    return false unless workspace&.membership_for(user)

    case key
    when "today" then workspace.cohorts.any? { |cohort| ChallengePrivacy::Access.staff_allowed?(cohort, user) }
    # Cohorts, people and Support's inbox all sit behind program management.
    when "people", "support" then CoachWorkspaces::ParticipantRosterPolicy.new(user: user, workspace: workspace).manage?
    when "groups", "settings" then workspace.allows?(user, :manage_members)
    when "coaching" then Mia::PersonaStudioPolicy.new(user, workspace: workspace).can_view?
    when "reports" then workspace.cohorts.any? { |cohort| ChallengePrivacy::Access.staff_allowed?(cohort, user, export: true) }
    else false
    end
  end
  private_class_method :allowed?
end
