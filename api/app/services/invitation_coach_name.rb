# frozen_string_literal: true

class InvitationCoachName
  def self.for(user:, invited_by:)
    return "Your coaching team" unless invited_by

    workspace_ids = user.cohort_memberships.joins(:cohort).distinct.pluck("cohorts.coach_workspace_id")
    workspace = CoachWorkspace.find_by(id: workspace_ids.sole) if workspace_ids.one?
    workspace ||= invited_by.coach_workspaces.first if invited_by.coach_workspaces.count == 1
    candidates = [ workspace&.coach_profile&.display_name, [ invited_by.first_name, invited_by.last_name ].compact_blank.join(" ") ]
    alias_stem = invited_by.email.to_s.split("@").first.to_s.split("+").first.to_s.downcase
    candidates.find { |name| name.present? && !name.match?(/[@+\r\n]/) && name.strip.downcase != alias_stem } || "Your coaching team"
  end
end
