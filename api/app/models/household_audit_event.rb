class HouseholdAuditEvent < ApplicationRecord
  ACTOR_TYPES = %w[user mia system].freeze

  belongs_to :household
  belongs_to :user, optional: true

  validates :actor_type, inclusion: { in: ACTOR_TYPES }
  validates :event_type, presence: true, length: { maximum: 120 }
  validates :occurred_at, presence: true
  validates :metadata, presence: true
end
