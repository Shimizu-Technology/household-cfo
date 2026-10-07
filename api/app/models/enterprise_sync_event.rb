class EnterpriseSyncEvent < ApplicationRecord
  validates :workos_event_id, presence: true, uniqueness: true
  validates :event_type, :occurred_at, presence: true
end
