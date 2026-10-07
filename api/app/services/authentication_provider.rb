require "jwt"
require "uri"

class AuthenticationProvider
  class ConfigurationError < StandardError; end
  class InvalidToken < StandardError; end

  class << self
    def mode
      value = ENV.fetch("AUTH_PROVIDER", "clerk")
      raise ConfigurationError, "Authentication provider is not configured" unless value.in?(%w[clerk workos transition])
      value
    end

    def for_token(token)
      selected = mode
      return selected unless selected == "transition"

      issuers = transition_issuers
      raise InvalidToken, "Invalid authentication token" unless token.is_a?(String) && token.present? && token.bytesize <= 16_384
      # Unverified claims select one verifier only. They grant no identity or access.
      claims = JWT.decode(token, nil, false).first
      provider = issuers[claims["iss"]] if claims.is_a?(Hash) && claims["iss"].is_a?(String)
      raise InvalidToken, "Unknown authentication issuer" unless provider
      provider
    rescue JWT::DecodeError, ArgumentError, TypeError
      raise InvalidToken, "Invalid authentication token"
    end

    def public_provider
      selected = mode
      return selected unless selected == "transition"

      transition_issuers
      provider = ENV["AUTH_PUBLIC_PROVIDER"]
      raise ConfigurationError, "Public authentication provider is not configured" unless provider.in?(%w[clerk workos])
      provider
    end

    def workos_enabled?
      selected = mode
      transition_issuers if selected == "transition"
      selected.in?(%w[workos transition]) && WorkosAuth.configured?
    end

    private

    def transition_issuers
      clerk_issuer = ENV["CLERK_ISSUER"]
      unless valid_clerk_issuer?(clerk_issuer) && ClerkAuth.configured? && WorkosAuth.configured?
        raise ConfigurationError, "Transition authentication requires configured Clerk and WorkOS issuers"
      end
      workos_issuer = WorkosAuth.issuer
      raise ConfigurationError, "Authentication issuers must be distinct" if clerk_issuer == workos_issuer
      { clerk_issuer => "clerk", workos_issuer => "workos" }
    end

    def valid_clerk_issuer?(value)
      return false unless value.is_a?(String) && value.present? && value == value.strip
      uri = URI.parse(value)
      uri.scheme == "https" && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end
  end
end
