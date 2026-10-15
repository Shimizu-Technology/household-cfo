class AuthenticationProvider
  class ConfigurationError < StandardError; end

  PROVIDER = "workos".freeze

  class << self
    # WorkOS is the only identity provider. AUTH_PROVIDER may be omitted; any other
    # value fails closed so a stale deployment setting cannot select a removed path.
    def mode
      value = ENV["AUTH_PROVIDER"].presence || PROVIDER
      raise ConfigurationError, "Authentication provider is not configured" unless value == PROVIDER
      value
    end

    def public_provider
      mode
    end

    def workos_enabled?
      mode == PROVIDER && WorkosAuth.configured?
    end
  end
end
