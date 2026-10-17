# frozen_string_literal: true

# Append-only record of an admin opening or pausing a cohort's savings challenge.
class CohortChallengeAccessEvent < ApplicationRecord
  ACTIONS = %w[open pause].freeze
  STATES = %w[not_set_up ready open paused].freeze

  belongs_to :cohort
  belongs_to :coach_workspace
  belongs_to :actor_user, class_name: "User"
  belongs_to :cohort_release, optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :from_state, :to_state, inclusion: { in: STATES }
  validates :actor_role_snapshot, inclusion: { in: %w[platform_admin] }
  validates :reason, length: { minimum: 5, maximum: 500 }
  validates :request_key, presence: true, length: { maximum: 255 }, uniqueness: { scope: :cohort_id }
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :occurred_at, presence: true
  validate :immutable_record, on: :update

  before_destroy { errors.add(:base, "challenge access events cannot be deleted"); throw :abort }

  private

  def immutable_record
    errors.add(:base, "challenge access events are immutable") if has_changes_to_save?
  end
end
