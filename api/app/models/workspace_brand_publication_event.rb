# frozen_string_literal: true

class WorkspaceBrandPublicationEvent < ApplicationRecord
  EVENT_TYPES = %w[publish rollback].freeze

  belongs_to :workspace_brand_configuration, inverse_of: :publication_events
  belongs_to :coach_workspace
  belongs_to :workspace_brand_version, inverse_of: :publication_events
  belongs_to :actor_user, class_name: "User", inverse_of: :workspace_brand_publication_events
  belongs_to :source_version, class_name: "WorkspaceBrandVersion", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :idempotency_key, presence: true, length: { maximum: 255 },
    uniqueness: { scope: :workspace_brand_configuration_id }
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :actor_is_staff
  validate :versions_belong_to_configuration
  validate :workspace_matches_configuration
  validate :source_matches_event
  validate :persisted_event_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def actor_is_staff
    errors.add(:actor_user, "must be a coach or admin") unless actor_user&.staff?
  end

  def versions_belong_to_configuration
    if workspace_brand_version&.workspace_brand_configuration != workspace_brand_configuration
      errors.add(:workspace_brand_version, "must belong to this configuration")
    end
    if source_version && source_version.workspace_brand_configuration != workspace_brand_configuration
      errors.add(:source_version, "must belong to this configuration")
    end
  end

  def source_matches_event
    errors.add(:source_version, "is required for a rollback") if event_type == "rollback" && source_version.nil?
    errors.add(:source_version, "must be blank for a publish") if event_type == "publish" && source_version.present?
  end

  def workspace_matches_configuration
    return if workspace_brand_configuration.nil? || coach_workspace_id == workspace_brand_configuration.coach_workspace_id

    errors.add(:coach_workspace, "must match the brand configuration")
  end

  def persisted_event_is_immutable
    errors.add(:base, "publication events are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "publication events cannot be deleted")
    throw :abort
  end
end
