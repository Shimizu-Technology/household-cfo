class ChallengeSupportAccess < ApplicationRecord
  include ChallengePrivacyScoped
  belongs_to :challenge_support_ticket
  belongs_to :recipient_user, class_name: "User"
  validates :reason, presence: true, length: { maximum: 500 }
  validates :expires_at, presence: true
  def active?(at: Time.current) = revoked_at.nil? && expires_at > at
end
