# frozen_string_literal: true

class CoachPersonaSetupSession < ApplicationRecord
  STATUSES = %w[active completed abandoned].freeze

  belongs_to :coach_persona
  belongs_to :coach_workspace
  belongs_to :created_by_user, class_name: "User"
  has_many :turns, -> { order(:position) }, class_name: "CoachPersonaSetupTurn", dependent: :restrict_with_exception
  has_many :proposals, through: :turns, source: :proposal

  validates :status, inclusion: { in: STATUSES }
  validates :base_draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :base_config_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :last_activity_at, presence: true
  validate :workspace_matches_persona

  scope :active, -> { where(status: "active") }

  private

  def workspace_matches_persona
    return if coach_persona.nil? || coach_persona.coach_workspace_id == coach_workspace_id

    errors.add(:coach_workspace, "must match the persona workspace")
  end
end
