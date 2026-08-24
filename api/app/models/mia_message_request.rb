class MiaMessageRequest < ApplicationRecord
  STATUSES = %w[processing completed].freeze
  REQUEST_KEY_FORMAT = /\A[a-zA-Z0-9._:-]+\z/

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

  def complete!(payload, response_status: 201)
    update!(
      status: "completed",
      response_payload: payload,
      response_status: response_status,
      completed_at: Time.current
    )
  end
end
