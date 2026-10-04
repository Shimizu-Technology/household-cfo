require "action_mailer"

class ChallengeReminderMailer < ActionMailer::Base
  self.logger = ActiveSupport::Logger.new(IO::NULL)

  def daily_check_in(recipient:, sender:, public_app_url:, delivery_key:)
    # A Message-ID identifies this generic delivery; SMTP does not guarantee
    # deduplication, so it is never treated as provider idempotency.
    mail(to: recipient, from: sender, subject: ChallengeReminders::Delivery::GENERIC_MESSAGE[:title],
      content_type: "text/plain", message_id: "<#{delivery_key}@#{Mail::Address.new(sender).domain}>",
      body: "#{ChallengeReminders::Delivery::GENERIC_MESSAGE[:body]}\n\n#{public_app_url}\n")
  end
end
