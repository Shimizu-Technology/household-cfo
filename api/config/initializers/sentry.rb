if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV.fetch("SENTRY_DSN")
    config.environment = Rails.env
    config.enabled_environments = %w[production staging]
    config.sample_rate = 1.0
    config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.1").to_f.clamp(0.0, 1.0)
    config.send_default_pii = false
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
    config.excluded_exceptions += %w[ActiveRecord::RecordNotFound ActionController::RoutingError ActionController::BadRequest]
    config.before_send = lambda do |event, _hint|
      event.request.data = nil if event.request
      event
    end
  end
end
