class SavingsChatCard < ApplicationRecord
  belongs_to :savings_enrollment
  belongs_to :chat_message
  validates :kind, inclusion: { in: %w[daily_report goal] }
  validates :status, inclusion: { in: %w[pending closed] }
  validate :private_envelope
  validate :bounded_state

  scope :for_picture, ->(generation) { joins(:chat_message).where(chat_messages: { financial_generation: generation }) }

  def as_api_json
    { id: id, kind: kind, input: input, state: state, status: status, lock_version: lock_version,
      enrollment_id: savings_enrollment_id, message_id: chat_message_id }
  end

  private

  def private_envelope
    enrollment = savings_enrollment
    message = chat_message
    return unless enrollment && message
    session = message.chat_session
    errors.add(:base, "Card must belong to its participant's challenge conversation") unless message.role == "assistant" &&
      session.household_id == enrollment.household_id && session.user_id == enrollment.user_id && session.cohort_id == enrollment.cohort_id
    errors.add(:input, "must be a bounded object") unless input.is_a?(Hash) && JSON.generate(input).bytesize <= 16_000
  end

  def bounded_state
    errors.add(:state, "must be a bounded object") unless state.is_a?(Hash) && JSON.generate(state).bytesize <= 40_000
  end
end
