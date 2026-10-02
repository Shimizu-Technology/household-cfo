# frozen_string_literal: true

configured = ENV["CONTENT_SOURCE_URL_INTAKE_ENABLED"]
Rails.application.config.x.content_source_url_intake_enabled = if configured.nil?
  Rails.env.development? || Rails.env.test?
else
  ActiveModel::Type::Boolean.new.cast(configured)
end
