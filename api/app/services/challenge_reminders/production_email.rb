require "uri"
require "digest"

module ChallengeReminders
  class ProductionEmail
    def initialize(env: ENV, mailer: ChallengeReminderMailer)
      @env, @mailer = env, mailer
    end

    def enabled?
      @env["REMINDERS_EMAIL_ENABLED"] == "true" && @env["REMINDERS_SENDER_VERIFIED"] == "true" &&
        @mailer.perform_deliveries == true && valid_address?(sender) && public_app_url.present? && smtp_settings.present?
    end
    def supports_idempotency? = false
    def idempotency_namespace
      return "disabled" unless enabled?
      "smtp_v1_#{Digest::SHA256.hexdigest(JSON.generate(smtp_settings.except(:password).merge(sender: sender, public_app_url: public_app_url)))}"
    end
    def deliver(recipient:, delivery_key:, message:)
      return :not_sent unless enabled? && valid_address?(recipient) && message == Delivery::GENERIC_MESSAGE && /\A[0-9a-f-]{36}\z/.match?(delivery_key)
      @mailer.smtp_settings = smtp_settings
      @mailer.delivery_method = :smtp
      @mailer.raise_delivery_errors = true
      @mailer.daily_check_in(recipient: recipient, sender: sender, public_app_url: public_app_url, delivery_key: delivery_key).deliver_now
      :delivered
      # No rescue/retry here: delivery owns the durable unknown state and never
      # records an exception message, recipient or SMTP credentials.
    end

    private

    def sender = (@env["REMINDERS_FROM_EMAIL"].presence || @env["MAILER_FROM_EMAIL"].presence).to_s
    def valid_address?(value)
      return false unless value.is_a?(String) && value.length <= 254 && !value.match?(/[\r\n]/)
      address = Mail::Address.new(value)
      address.address == value && address.local.present? && address.domain.to_s.match?(/\A[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/)
    rescue Mail::Field::ParseError, ArgumentError
      false
    end

    def public_app_url
      uri = URI.parse((@env["REMINDERS_PUBLIC_APP_URL"].presence || @env["FRONTEND_URL"].presence).to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.port == 443 && uri.path.in?([ "", "/" ])
      return if uri.host.in?(%w[localhost 127.0.0.1 ::1]) || uri.host.end_with?(".local") || !uri.host.include?(".")
      return unless uri.host.match?(/\A[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/)
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def smtp_settings
      # This API previously used Resend invites, not SMTP. Reuse explicit
      # ActionMailer transport settings if supplied, otherwise require SMTP
      # address configuration. Timeouts and certificate checks stay bounded.
      inherited = @mailer.smtp_settings.to_h.symbolize_keys
      address = @env["SMTP_ADDRESS"].presence || inherited[:address]
      return if address.blank? || address.in?(%w[localhost 127.0.0.1])
      port = Integer(@env["SMTP_PORT"].presence || (@env["SMTP_ADDRESS"].present? ? 587 : inherited[:port]) || 587)
      return unless port.in?([ 465, 587 ])
      username = @env["SMTP_USERNAME"].presence || inherited[:user_name]
      password = @env["SMTP_PASSWORD"].presence || inherited[:password]
      return if username.present? && password.blank?
      { address: address, port: port, domain: @env["SMTP_DOMAIN"].presence || inherited[:domain] || Mail::Address.new(sender).domain,
        user_name: username, password: password, authentication: username.present? ? :plain : nil,
        enable_starttls: port == 587, enable_starttls_auto: false, ssl: port == 465, openssl_verify_mode: "peer", open_timeout: 5, read_timeout: 10 }
    rescue ArgumentError, TypeError
      nil
    end
  end
end
