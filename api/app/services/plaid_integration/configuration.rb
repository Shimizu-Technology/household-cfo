module PlaidIntegration
  class Configuration
    CONSENT_POLICY_VERSION = "2026-07-14".freeze

    class << self
      def environment
        value = ENV.fetch("PLAID_ENV", "sandbox")
        raise Error, "Plaid environment must be sandbox or production" unless value.in?(PlaidItem::ENVIRONMENTS)

        value
      end

      def configured?
        ENV["PLAID_CLIENT_ID"].present? && ENV["PLAID_SECRET"].present? && ENV["PLAID_DATA_ENCRYPTION_KEY"].present?
      end

      def validate!
        raise Error, "Plaid is not configured for this environment" unless configured?
      end

      def webhook_url
        ENV["PLAID_WEBHOOK_URL"].presence
      end
    end
  end
end
