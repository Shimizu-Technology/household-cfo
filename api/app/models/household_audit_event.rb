class HouseholdAuditEvent < ApplicationRecord
  ACTOR_TYPES = %w[user mia system].freeze

  belongs_to :household
  belongs_to :user, optional: true

  validates :actor_type, inclusion: { in: ACTOR_TYPES }
  validates :event_type, presence: true, length: { maximum: 120 }
  validates :occurred_at, presence: true
  validate :metadata_must_be_an_object

  private

  def metadata_must_be_an_object
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end
end
