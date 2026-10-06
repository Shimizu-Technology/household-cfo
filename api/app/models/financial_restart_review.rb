class FinancialRestartReview < ApplicationRecord
  belongs_to :household
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :cohort, optional: true
  belongs_to :setup_support_request, optional: true
  validates :purpose, inclusion: { in: %w[admin_test self_setup supported_setup] }
  validates :status, inclusion: { in: %w[pending applied canceled] }
  validates :inventory_fingerprint, :expires_at, presence: true
end
