class MiaMessageRequest < ApplicationRecord
  STATUSES = %w[processing completed failed].freeze
  REQUEST_KEY_FORMAT = /\A[a-zA-Z0-9._:-]+\z/
  STALE_AFTER = 3.minutes
  FAILURE_RESPONSE = {
    "status" => "failed",
    "code" => "mia_request_failed",
    "error" => "Mia could not finish that request safely. Your approved household numbers were not changed; send the message again."
  }.freeze

  belongs_to :chat_session

  validates :request_key,
            presence: true,
            length: { maximum: 100 },
            format: { with: REQUEST_KEY_FORMAT }
  validates :request_fingerprint, presence: true, length: { is: 64 }
  validates :status, inclusion: { in: STATUSES }
  validates :request_key, uniqueness: { scope: :chat_session_id }

  def processing?
    status == "processing"
  end

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
  end

  def stale?
    processing? && updated_at <= STALE_AFTER.ago
  end

  def complete!(payload, response_status: 201)
    update!(
      status: "completed",
      response_payload: payload,
      response_status: response_status,
      completed_at: Time.current
    )
  end

  def fail!
    return unless processing?

    update!(
      status: "failed",
      response_payload: FAILURE_RESPONSE,
      response_status: 503,
      completed_at: Time.current
    )
  end

  def expire_if_stale!
    fail! if stale?
  end
end
