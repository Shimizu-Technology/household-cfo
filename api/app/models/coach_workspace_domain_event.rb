# frozen_string_literal: true

class CoachWorkspaceDomainEvent < ApplicationRecord
  EVENT_TYPES = %w[created verification_requested verified activated disabled].freeze

  belongs_to :coach_workspace_domain, inverse_of: :lifecycle_events
  belongs_to :coach_workspace
  belongs_to :actor_user, class_name: "User", inverse_of: :coach_workspace_domain_events

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validate :actor_is_staff
  validate :workspace_matches_domain
  validate :persisted_event_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def actor_is_staff
    errors.add(:actor_user, "must be a coach or admin") unless actor_user&.staff?
  end

  def persisted_event_is_immutable
    errors.add(:base, "domain lifecycle events are immutable") if has_changes_to_save?
  end

  def workspace_matches_domain
    return if coach_workspace_domain.nil? || coach_workspace_id == coach_workspace_domain.coach_workspace_id

    errors.add(:coach_workspace, "must match the domain")
  end

  def prevent_destroy
    errors.add(:base, "domain lifecycle events cannot be deleted")
    throw :abort
  end
end
