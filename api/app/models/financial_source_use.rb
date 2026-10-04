class FinancialSourceUse < ApplicationRecord
  include ChallengePrivacyScoped
  belongs_to :financial_document_import, optional: true
  validates :expires_at, :authorized_at, :disclosure_version, presence: true
  def active?(at: Time.current) = revoked_at.nil? && expires_at > at
end
