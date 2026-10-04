# frozen_string_literal: true

class CoachWorkspaceMembershipEvent < ApplicationRecord
  belongs_to :coach_workspace
  belongs_to :actor_user, class_name: "User"
  belongs_to :subject_user, class_name: "User"
  validates :event_type, inclusion: { in: %w[added role_changed removed] }
  validates :before_role, :after_role, inclusion: { in: CoachWorkspaceMembership::ROLES }, allow_nil: true
  validate :actor_can_manage_workspace, on: :create
  validate :immutable_event, on: :update
  before_destroy :prevent_destroy

  private

  def actor_can_manage_workspace
    return if actor_user&.staff? && coach_workspace&.allows?(actor_user, :manage_members)

    errors.add(:actor_user, "cannot manage this workspace's collaborators")
  end

  def immutable_event
    errors.add(:base, "Collaborator access history cannot be changed.") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "Collaborator access history cannot be deleted.")
    throw :abort
  end
end
