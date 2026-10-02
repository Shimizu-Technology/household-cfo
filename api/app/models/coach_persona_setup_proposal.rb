# frozen_string_literal: true

class CoachPersonaSetupProposal < ApplicationRecord
  STATUSES = %w[pending applied rejected superseded stale].freeze

  belongs_to :session, class_name: "CoachPersonaSetupSession", foreign_key: :coach_persona_setup_session_id
  belongs_to :turn, class_name: "CoachPersonaSetupTurn", foreign_key: :coach_persona_setup_turn_id,
    inverse_of: :proposal
  belongs_to :resolved_by_user, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :base_draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :base_config_digest, :proposal_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :operations, length: { maximum: 24 }
  validates :prompt_version, :schema_version, presence: true, length: { maximum: 120 }
  validates :resolution_idempotency_key, length: { maximum: 200 }, allow_nil: true
  validate :turn_belongs_to_session
  validate :payload_is_immutable, on: :update
  validate :final_proposal_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def turn_belongs_to_session
    return if turn.nil? || turn.coach_persona_setup_session_id == coach_persona_setup_session_id

    errors.add(:turn, "must belong to the setup session")
  end

  def final_proposal_is_immutable
    return if status_was == "pending"

    permitted = %w[updated_at lock_version]
    errors.add(:base, "resolved proposal is immutable") if changes_to_save.keys.excluding(*permitted).any?
  end

  def payload_is_immutable
    immutable = %w[
      coach_persona_setup_session_id coach_persona_setup_turn_id base_draft_revision base_config_digest
      operations before_state after_state proposal_digest prompt_version schema_version
    ]
    errors.add(:base, "proposal payload is immutable") if changes_to_save.keys.intersect?(immutable)
  end

  def prevent_destroy
    errors.add(:base, "setup proposals are an immutable audit record")
    throw :abort
  end

  public

  def resolve!(status:, actor:, idempotency_key: nil)
    raise ArgumentError, "unsupported proposal resolution" unless status.in?(%w[applied rejected superseded stale])

    update!(
      status:,
      resolved_by_user: actor,
      resolved_at: Time.current,
      resolution_idempotency_key: idempotency_key
    )
  end
end
