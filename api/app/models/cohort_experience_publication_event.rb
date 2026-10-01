# frozen_string_literal: true

class CohortExperiencePublicationEvent < ApplicationRecord
  EVENT_TYPES = %w[publish rollback].freeze

  belongs_to :cohort_experience_configuration, inverse_of: :publication_events
  belongs_to :cohort_experience_version, inverse_of: :publication_events
  belongs_to :actor_user, class_name: "User", inverse_of: :cohort_experience_publication_events
  belongs_to :source_version, class_name: "CohortExperienceVersion", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validate :actor_is_staff
  validate :versions_belong_to_configuration
  validate :source_matches_event
  validate :persisted_event_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def actor_is_staff
    errors.add(:actor_user, "must be a coach or admin") unless actor_user&.staff?
  end

  def versions_belong_to_configuration
    if cohort_experience_version&.cohort_experience_configuration != cohort_experience_configuration
      errors.add(:cohort_experience_version, "must belong to this configuration")
    end
    if source_version && source_version.cohort_experience_configuration != cohort_experience_configuration
      errors.add(:source_version, "must belong to this configuration")
    end
  end

  def source_matches_event
    errors.add(:source_version, "is required for a rollback") if event_type == "rollback" && source_version.nil?
    errors.add(:source_version, "must be blank for a publish") if event_type == "publish" && source_version.present?
  end

  def persisted_event_is_immutable
    errors.add(:base, "publication events are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "publication events cannot be deleted")
    throw :abort
  end
end
