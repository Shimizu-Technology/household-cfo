module PlaidIntegration
  class Client
    class << self
      def instance
        Configuration.validate!
        configuration = Plaid::Configuration.new
        configuration.server_index = Plaid::Configuration::Environment.fetch(Configuration.environment)
        configuration.api_key["PLAID-CLIENT-ID"] = ENV.fetch("PLAID_CLIENT_ID")
        configuration.api_key["PLAID-SECRET"] = ENV.fetch("PLAID_SECRET")
        Plaid::PlaidApi.new(Plaid::ApiClient.new(configuration))
      end

      def safely
        yield instance
      rescue Plaid::ApiError => e
        payload = JSON.parse(e.response_body.to_s)
        code = payload["error_code"]
        message = user_message(code)
        raise Error.new(message, code: code)
      rescue JSON::ParserError
        raise Error, "Plaid could not complete that request"
      end

      private

      def user_message(code)
        return "This bank connection needs attention. Reconnect it and try again." if code.to_s.start_with?("ITEM_LOGIN") || code == "INVALID_CREDENTIALS"

        "Plaid could not complete that request. Please try again."
      end
    end
  end
end
