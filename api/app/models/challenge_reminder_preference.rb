class ChallengeReminderPreference < ApplicationRecord
  include ChallengePrivacyScoped
  CHANNELS = %w[in_app email].freeze
  POLICY_VERSION = "generic_daily_reminder_v1".freeze
  CLOCK = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/.freeze
  validates :channel, inclusion: { in: CHANNELS }
  validates :local_time, :quiet_start, :quiet_end, format: { with: CLOCK }
  validates :policy_version, inclusion: { in: [ POLICY_VERSION ] }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :channel, uniqueness: { scope: :savings_enrollment_id }

  def self.defaults(channel)
    { channel: channel, enabled: channel == "in_app", local_time: "18:00", quiet_start: "21:00", quiet_end: "08:00", policy_version: POLICY_VERSION }
  end

  def quiet?(local)
    clock = local.strftime("%H:%M")
    return false if quiet_start == quiet_end
    quiet_start < quiet_end ? clock >= quiet_start && clock < quiet_end : clock >= quiet_start || clock < quiet_end
  end
end
