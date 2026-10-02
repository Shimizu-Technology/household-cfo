# frozen_string_literal: true

module ContentSources
  module UrlIntake
    class << self
      def enabled?
        Rails.application.config.x.content_source_url_intake_enabled == true
      end

      def available?
        enabled? && S3Service.configured? && UrlCipher.configured?
      end
    end
  end
end
