# frozen_string_literal: true

require "uri"

module HouseholdFinance
  module MiaProviderEndpoint
    DEFAULT_URL = "https://openrouter.ai/api/v1/chat/completions"

    module_function

    def uri(value = ENV.fetch("OPENROUTER_MIA_URL", DEFAULT_URL))
      parsed = URI(value.to_s)
      valid_scheme = parsed.scheme.in?(%w[http https])
      production_scheme = !Rails.env.production? || parsed.scheme == "https"
      raise ArgumentError, "Mia provider URL must be a valid HTTPS endpoint" unless valid_scheme && production_scheme && parsed.host.present?

      parsed
    end
  end
end
