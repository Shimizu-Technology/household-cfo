class SetupHelpRequestKey < ApplicationRecord
  belongs_to :household
  belongs_to :user
  belongs_to :setup_support_request
  validates :idempotency_key, presence: true, length: { maximum: 200 }
  validates :request_fingerprint, presence: true
end
