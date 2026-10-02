# frozen_string_literal: true

Rails.application.config.after_initialize do
  if Rails.env.production? && S3Service.configured?
    ContentSources::UrlCipher.validate_configuration!
  end
end
