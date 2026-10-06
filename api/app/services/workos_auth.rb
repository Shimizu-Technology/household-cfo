require "httparty"
require "jwt"
require "openssl"

class WorkosAuth
  class Unavailable < StandardError; end
  class InvalidToken < StandardError; end

  JWKS_TTL = 1.hour
  REFRESH_COOLDOWN = 30.seconds
  REFRESH_MUTEX = Mutex.new

  class << self
    def client_id
      ENV["WORKOS_CLIENT_ID"].to_s
    end

    def api_origin
      hostname = ENV.fetch("WORKOS_API_HOSTNAME", "api.workos.com")
      raise Unavailable, "WorkOS authentication configuration is invalid" unless hostname.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/i)
      "https://#{hostname}"
    end

    def issuer
      ENV.fetch("WORKOS_ISSUER", api_origin)
    end

    def configured?
      client_id.match?(/\Aclient_[a-zA-Z0-9]+\z/) && ENV["WORKOS_API_KEY"].present? &&
        issuer.match?(/\Ahttps:\/\/[a-z0-9]+(?:[.-][a-z0-9]+)*\z/i)
    rescue Unavailable
      false
    end

    def verify(token)
      raise Unavailable, "WorkOS authentication is not configured" unless configured?
      raise InvalidToken, "Invalid authentication token" if token.blank? || token.bytesize > 16_384

      # Parse only to choose a key. Neither these claims nor token-supplied URLs are trusted.
      _unverified, header = JWT.decode(token, nil, false)
      raise InvalidToken, "Invalid authentication token" unless header["alg"] == "RS256" && header["kid"].is_a?(String) && header["kid"].present?

      jwks = fetch_jwks
      unless jwks.fetch("keys").any? { |key| key["kid"] == header["kid"] }
        jwks = refresh_jwks
      end
      claims = JWT.decode(token, nil, true, algorithms: [ "RS256" ], jwks: jwks,
        iss: issuer, verify_iss: true, verify_expiration: true, required_claims: %w[iss sub sid exp]).first
      unless claims["sub"].is_a?(String) && claims["sub"].match?(/\Auser_[a-zA-Z0-9]+\z/) &&
          claims["sid"].is_a?(String) && claims["sid"].match?(/\Asession_[a-zA-Z0-9]+\z/) &&
          claims["exp"].is_a?(Numeric) && claims["client_id"] == client_id
        raise InvalidToken, "Invalid authentication token"
      end
      claims
    rescue JWT::DecodeError, ArgumentError, TypeError
      raise InvalidToken, "Invalid or expired authentication token"
    end

    def fetch_user_profile(subject)
      raise Unavailable, "WorkOS authentication is not configured" unless configured?
      raise InvalidToken, "Invalid WorkOS user" unless subject.to_s.match?(/\Auser_[a-zA-Z0-9]+\z/)
      data = request_json("#{api_origin}/user_management/users/#{subject}", authenticated: true)
      raise InvalidToken, "WorkOS user is unavailable" unless data["id"] == subject
      unless data["email"].is_a?(String) && data["email"].present? &&
          %w[first_name last_name].all? { |field| data[field].nil? || data[field].is_a?(String) }
        raise Unavailable, "WorkOS authentication service returned an invalid profile"
      end
      { id: data["id"], email: data["email"], email_verified: data["email_verified"] == true,
        first_name: data["first_name"], last_name: data["last_name"] }
    end

    private

    def cache_key
      "workos:jwks:#{api_origin}:#{client_id}"
    end

    def refresh_jwks
      # Unknown kids may signal rotation. Limit repeated attacker-driven refreshes per process/cache.
      REFRESH_MUTEX.synchronize do
        return fetch_jwks if Rails.cache.read("#{cache_key}:refresh")
        Rails.cache.write("#{cache_key}:refresh", true, expires_in: REFRESH_COOLDOWN)
        fetch_jwks(force: true)
      end
    end

    def fetch_jwks(force: false)
      cached = Rails.cache.read(cache_key) unless force
      return cached if cached
      data = request_json("#{api_origin}/sso/jwks/#{client_id}")
      keys = data["keys"]
      unless keys.is_a?(Array) && keys.present? && keys.all? { |key| key.is_a?(Hash) && key["kid"].is_a?(String) && key["kty"] == "RSA" && key["n"].present? && key["e"].present? }
        raise Unavailable, "WorkOS signing keys are unavailable"
      end
      begin
        keys.each { |key| JWT::JWK.import(key).public_key }
      rescue JWT::JWKError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError
        raise Unavailable, "WorkOS signing keys are unavailable"
      end
      Rails.cache.write(cache_key, data, expires_in: JWKS_TTL)
      data
    end

    def request_json(url, authenticated: false)
      headers = { "Accept" => "application/json" }
      headers["Authorization"] = "Bearer #{ENV.fetch('WORKOS_API_KEY')}" if authenticated
      response = HTTParty.get(url, headers: headers, timeout: 5, open_timeout: 3, follow_redirects: false)
      raise InvalidToken, "WorkOS user is unavailable" if authenticated && response.code == 404
      raise Unavailable, "WorkOS authentication service is unavailable" unless response.success?
      data = response.parsed_response
      raise Unavailable, "WorkOS authentication service returned an invalid response" unless data.is_a?(Hash)
      data
    rescue HTTParty::Error, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError
      # Exceptions may contain request details. Never log credentials or token data.
      raise Unavailable, "WorkOS authentication service is unavailable"
    end
  end
end
