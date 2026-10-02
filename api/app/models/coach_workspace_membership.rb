# frozen_string_literal: true

class CoachWorkspaceMembership < ApplicationRecord
  ROLES = %w[owner editor reviewer viewer].freeze

  belongs_to :coach_workspace, inverse_of: :coach_workspace_memberships
  belongs_to :user, inverse_of: :coach_workspace_memberships

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :coach_workspace_id }
  validate :member_is_staff

  private

  def member_is_staff
    errors.add(:user, "must be a coach or administrator") unless user&.staff?
  end
end
