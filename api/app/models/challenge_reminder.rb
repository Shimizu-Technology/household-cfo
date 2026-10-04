class ChallengeReminder < ApplicationRecord
  include ChallengePrivacyScoped
  belongs_to :challenge_reminder_preference
  STATUSES = %w[pending leased delivered cancelled failed unknown].freeze
  REASONS = %w[scheduled available delivered preference_disabled participant_unavailable outside_personal_day quiet_hours before_local_time attendance_confirmed channel_disabled retry_wait attempts_exhausted delivery_unknown lease_recovered dismissed].freeze
  validates :channel, inclusion: { in: ChallengeReminderPreference::CHANNELS }
  validates :status, inclusion: { in: STATUSES }
  validates :reason_code, inclusion: { in: REASONS }
  validates :local_on, :delivery_key, :next_attempt_at, presence: true
  scope :due, -> { where(status: "pending").where("next_attempt_at <= ?", Time.current) }
end
