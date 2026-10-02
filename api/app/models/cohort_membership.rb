class CohortMembership < ApplicationRecord
  ROLES = %w[participant coach admin].freeze

  belongs_to :cohort
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :cohort_id }

  after_create :ensure_coach_workspace_access

  private

  def ensure_coach_workspace_access
    return unless role.in?(%w[coach admin]) && user&.coach?
    return if cohort.coach_workspace.coach_workspace_memberships.exists?(user: user)

    cohort.coach_workspace.coach_workspace_memberships.create!(user: user, role: "editor")
  end
end
