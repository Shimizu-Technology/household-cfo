class ChallengeSourceLeaseExpiryJob < ApplicationJob
  queue_as :default
  def perform
    ChallengeReminders::SourceLeaseSweep.new.call
  end
end
