class FinancialRestartReview < ApplicationRecord
  belongs_to :household
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :cohort, optional: true
  validates :status, inclusion: { in: %w[pending applied canceled] }
  validates :inventory_fingerprint, :expires_at, presence: true
end
