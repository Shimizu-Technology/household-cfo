# frozen_string_literal: true

class CoachWorkspaceMembership < ApplicationRecord
  ROLES = %w[owner editor reviewer viewer].freeze

  belongs_to :coach_workspace, inverse_of: :coach_workspace_memberships
  belongs_to :user, inverse_of: :coach_workspace_memberships

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :coach_workspace_id }
  validate :member_is_staff

  before_update :mark_role_change_as_explicit
  # Losing a place on the workspace ends the person's preview seats in its groups.
  # After the commit, because ending a seat takes the person's household lock.
  after_commit :end_preview_seats, on: :destroy

  private

  def end_preview_seats
    PreviewSeats.release_unavailable!(user) if user
  end

  def mark_role_change_as_explicit
    self.cohort_managed = false if will_save_change_to_role?
  end

  def member_is_staff
    errors.add(:user, "must be a coach or administrator") unless user&.staff?
  end
end
