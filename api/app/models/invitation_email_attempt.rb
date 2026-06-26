class InvitationEmailAttempt < ApplicationRecord
  STATUSES = %w[not_sent skipped sent failed].freeze

  belongs_to :user
  belongs_to :sent_by_user, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :provider, presence: true
  validates :attempted_at, presence: true
  validate :sent_attempts_have_sent_at

  scope :recent_first, -> { order(attempted_at: :desc, id: :desc) }

  private

  def sent_attempts_have_sent_at
    errors.add(:sent_at, "is required when status is sent") if status == "sent" && sent_at.blank?
  end
end
