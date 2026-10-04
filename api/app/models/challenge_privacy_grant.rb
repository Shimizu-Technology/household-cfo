class ChallengePrivacyGrant < ApplicationRecord
  include ChallengePrivacyScoped
  belongs_to :recipient_user, class_name: "User", optional: true
  KINDS = %w[coach_summary selected_details sponsor_aggregate].freeze
  validates :kind, inclusion: { in: KINDS }
  validates :policy_version, presence: true
  def active?(at: Time.current) = granted && (expires_at.nil? || expires_at > at)
end
