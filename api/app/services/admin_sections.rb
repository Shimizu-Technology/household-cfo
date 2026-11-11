# frozen_string_literal: true

# The sections of the Admin side a signed-in person may open. The server decides
# once, here, and /auth/me hands the list to the web, so the client never works
# out roles itself. The same names are the web routes: /admin/<key>.
#
# Each section's own APIs still enforce their permissions; this list only says
# what to show. `access` is "full" or "read_only".
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
    return SECTIONS.map { |section| section.merge(access: "full") } if user.admin?
    return [] unless workspace&.membership_for(user)

    SECTIONS.filter_map do |section|
      access = access_for(section.fetch(:key), workspace, user)
      section.merge(access: access) if access
    end
  end

  def self.access_for(key, workspace, user)
    manage = workspace.allows?(user, :manage_members)
    case key
    when "today", "support" then "full"
    when "people", "groups" then manage ? "full" : "read_only"
    when "coaching" then workspace.allows?(user, :edit) || workspace.allows?(user, :review) ? "full" : nil
    when "reports" then workspace.allows?(user, :review) ? "full" : nil
    when "settings" then manage ? "full" : nil
    end
  end
  private_class_method :access_for
end
