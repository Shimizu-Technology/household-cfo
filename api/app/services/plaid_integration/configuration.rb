require "uri"

module PlaidIntegration
  class Configuration
    CONSENT_POLICY_VERSION = "2026-08-16".freeze

    class << self
      def environment
        value = ENV.fetch("PLAID_ENV", "sandbox")
        raise Error, "Plaid environment must be sandbox or production" unless value.in?(PlaidItem::ENVIRONMENTS)

        value
      end

      def configured?
        validate!
        true
      rescue Error
        false
      end

      def validate!
        unless ENV["PLAID_CLIENT_ID"].present? && ENV["PLAID_SECRET"].present? && ENV["PLAID_DATA_ENCRYPTION_KEY"].present?
          raise Error, "Plaid is not configured for this environment"
        end

        return true unless environment == "production"

        validate_production_url!(webhook_url, name: "PLAID_WEBHOOK_URL", required_path: "/api/plaid/webhook")
        validate_production_url!(redirect_uri, name: "PLAID_REDIRECT_URI")
        true
      end

      def webhook_url
        ENV["PLAID_WEBHOOK_URL"].presence
      end

      def redirect_uri
        ENV["PLAID_REDIRECT_URI"].presence
      end

      def link_customization_name
        ENV["PLAID_LINK_CUSTOMIZATION_NAME"].presence
      end

      private

      def validate_production_url!(value, name:, required_path: nil)
        uri = URI.parse(value.to_s)
        valid = uri.scheme == "https" && uri.host.present? && uri.userinfo.nil?
        valid &&= uri.path == required_path if required_path
        raise Error, "#{name} must be a public HTTPS URL#{required_path ? " ending in #{required_path}" : ""} for Plaid production" unless valid
      rescue URI::InvalidURIError
        raise Error, "#{name} must be a valid public HTTPS URL for Plaid production"
      end
    end
  end
end
