# frozen_string_literal: true

class CoachContentSourceAttempt < ApplicationRecord
  STATUSES = %w[processing succeeded failed superseded].freeze

  belongs_to :coach_content_source
  has_many :candidates, class_name: "CoachContentSourceCandidate", dependent: :restrict_with_exception

  validates :generation, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :coach_content_source_id }
  validates :provider, :model, :prompt_version, :schema_version, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :started_at, presence: true
  validate :terminal_attempt_has_completed_at
  validate :attempt_identity_is_immutable, on: :update

  private

  def terminal_attempt_has_completed_at
    return if status == "processing" || completed_at.present?

    errors.add(:completed_at, "is required for a completed attempt")
  end

  def attempt_identity_is_immutable
    fields = %w[coach_content_source_id generation provider model prompt_version schema_version started_at]
    errors.add(:base, "source attempt identity is immutable") if changes_to_save.keys.intersect?(fields)
  end
end
