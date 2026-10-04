class ChallengeSupportTicket < ApplicationRecord
  include ChallengePrivacyScoped
  belongs_to :recipient_user, class_name: "User"
  validates :message, presence: true, length: { maximum: 500 }
  validates :issue_kind, inclusion: { in: %w[technical coaching access other] }
  validates :status, inclusion: { in: %w[open triaged resolved] }
end
