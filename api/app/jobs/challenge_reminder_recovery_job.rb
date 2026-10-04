class ChallengeReminderRecoveryJob < ApplicationJob
  queue_as :default
  def perform
    ChallengeReminders::Scheduler.new.call
    delivery = ChallengeReminders::Delivery.new
    delivery.recover
    delivery.call
  end
end
