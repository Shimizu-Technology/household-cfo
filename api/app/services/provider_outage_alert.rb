# frozen_string_literal: true

# Makes an AI provider outage visible. When OpenRouter refuses calls for
# account reasons (out of credits, bad or revoked key, access denied), every
# Mia reply quietly becomes a scripted fallback and document reading stops, so
# nobody notices. This logs an error, reports to Sentry when configured, and
# emails OPS_ALERT_EMAILS at most once an hour per reason.
# Never includes participant content: only the service, status, and the
# provider's own error message.
module ProviderOutageAlert
  ACCOUNT_FAILURES = {
    401 => "OpenRouter rejected the API key",
    402 => "OpenRouter account is out of credits",
    403 => "OpenRouter denied access"
  }.freeze
  EMAIL_INTERVAL = 1.hour

  module_function

  # Pass any provider response; only account-level failures alert.
  def check(response, service:)
    status = response.respond_to?(:code) ? response.code.to_i : nil
    reason = ACCOUNT_FAILURES[status]
    return unless reason

    detail = provider_message(response)
    Rails.logger.error({ event: "ai_provider_account_failure", service: service, status: status, reason: reason, provider_message: detail }.compact.to_json)
    report_to_sentry(service, status, reason, detail)
    email_ops(status, reason, service, detail)
  rescue StandardError => e
    Rails.logger.warn("[ProviderOutageAlert] alert failed: #{e.class}")
  end

  def provider_message(response)
    JSON.parse(response.body.to_s).dig("error", "message").to_s.truncate(200).presence
  rescue JSON::ParserError, TypeError
    nil
  end

  def report_to_sentry(service, status, reason, detail)
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.capture_message(reason, level: :error, tags: { ai_service: service, ai_status: status },
      extra: { provider_message: detail }, fingerprint: [ "ai_provider_account_failure", status ])
  end

  def email_ops(status, reason, service, detail)
    recipients = ENV.fetch("OPS_ALERT_EMAILS", "").split(",").map(&:strip).reject(&:blank?)
    from = ENV["MAILER_FROM_EMAIL"].presence || ENV["RESEND_FROM_EMAIL"].presence
    return if recipients.empty? || from.blank? || ENV["RESEND_API_KEY"].blank?
    return unless Rails.cache.write("ai_provider_account_failure:#{status}", true, unless_exist: true, expires_in: EMAIL_INTERVAL)

    Resend::Emails.send({
      from: from,
      to: recipients,
      subject: "Household CFO: #{reason}",
      text: [
        "#{reason} (HTTP #{status}). Mia is answering with scripted fallbacks and document reading is paused until this is fixed.",
        "First seen in: #{service}. Provider message: #{detail || 'none'}.",
        status == 402 ? "Add credits at https://openrouter.ai/settings/credits and consider enabling auto top-up." : "Check OPENROUTER_API_KEY on Render.",
        "You will get at most one of these per hour while the problem continues."
      ].join("\n\n")
    })
  end
end
