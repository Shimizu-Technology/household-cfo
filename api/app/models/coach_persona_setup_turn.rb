# frozen_string_literal: true

class CoachPersonaSetupTurn < ApplicationRecord
  STATUSES = %w[processing ready failed stale].freeze

  belongs_to :session, class_name: "CoachPersonaSetupSession", foreign_key: :coach_persona_setup_session_id,
    inverse_of: :turns
  has_one :proposal, class_name: "CoachPersonaSetupProposal", dependent: :restrict_with_exception,
    inverse_of: :turn

  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :idempotency_key, presence: true, length: { maximum: 200 }, uniqueness: { scope: :coach_persona_setup_session_id }
  validates :status, inclusion: { in: STATUSES }
  validates :user_message, presence: true, length: { maximum: 4_000 }
  validates :assistant_message, length: { maximum: 2_000 }, allow_nil: true
  validate :usage_is_sanitized
  validate :state_is_coherent

  private

  def usage_is_sanitized
    valid = usage.is_a?(Hash) && (usage.keys - %w[prompt_tokens completion_tokens total_tokens]).empty? &&
      usage.values.all? { |value| value.is_a?(Integer) && value.between?(0, 10_000_000) }
    errors.add(:usage, "contains unsupported provider metadata") unless valid
  end

  def state_is_coherent
    if status == "processing" && (assistant_message.present? || error_code.present?)
      errors.add(:status, "processing turn cannot have a response or error")
    elsif status == "ready" && (assistant_message.blank? || error_code.present?)
      errors.add(:status, "ready turn must have a response and no error")
    elsif status == "failed" && error_code.blank?
      errors.add(:status, "failed turn must have an error code")
    end
  end
end
