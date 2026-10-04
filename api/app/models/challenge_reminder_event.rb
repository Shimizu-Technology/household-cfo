class ChallengeReminderEvent < ApplicationRecord
  include ChallengePrivacyScoped
  include SavingsImmutable
  belongs_to :actor_user, class_name: "User"
  validates :action, inclusion: { in: %w[preference dismiss] }
  validates :subject_type, inclusion: { in: %w[ChallengeReminderPreference ChallengeReminder] }
end
