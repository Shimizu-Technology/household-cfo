require "httparty"
require "jwt"
require "openssl"

class ClerkAuth
  JWKS_CACHE_KEY = "clerk_jwks"
  JWKS_CACHE_TTL = 1.hour

  class << self
    def configured?
      jwks_url.present?
    end

    def verify(token, refreshed_jwks: false)
      return nil if token.blank?
      return handle_test_token(token) if Rails.env.test? && test_token?(token)

      jwks = fetch_jwks(force_refresh: refreshed_jwks)
      return nil unless jwks

      options = {
        algorithms: [ "RS256" ],
        jwks: jwks
      }

      audience = ENV.fetch("CLERK_AUDIENCE", ENV.fetch("CLERK_AUDIENCES", nil))
      if audience.present?
        options[:aud] = audience.split(",").map(&:strip)
        options[:verify_aud] = true
      end

      issuer = ENV.fetch("CLERK_ISSUER", nil)
      if issuer.present?
        options[:iss] = issuer
        options[:verify_iss] = true
      end

      JWT.decode(token, nil, true, options).first
    rescue JWT::ExpiredSignature
      Rails.logger.debug("Clerk JWT token expired")
      nil
    rescue JWT::DecodeError => e
      unless refreshed_jwks
        Rails.logger.warn("Clerk JWT decode error: #{e.message}; refreshing JWKS cache and retrying once")
        Rails.cache.delete(JWKS_CACHE_KEY)
        return verify(token, refreshed_jwks: true)
      end

      Rails.logger.warn("Clerk JWT decode error after JWKS refresh: #{e.message}")
      nil
    end

    def fetch_user_email(clerk_user_id)
      fetch_user_profile(clerk_user_id)&.dig(:email)
    end

    def fetch_user_profile(clerk_user_id)
      secret_key = ENV.fetch("CLERK_SECRET_KEY", nil)
      return nil if secret_key.blank? || clerk_user_id.blank?

      response = HTTParty.get(
        "https://api.clerk.com/v1/users/#{clerk_user_id}",
        headers: clerk_api_headers(secret_key),
        timeout: 5
      )
      return nil unless response.success?

      data = response.parsed_response
      primary_email_id = data["primary_email_address_id"]
      addresses = data["email_addresses"] || []
      primary_email = addresses.find { |address| address["id"] == primary_email_id } || addresses.first

      {
        email: primary_email&.dig("email_address"),
        first_name: data["first_name"].presence,
        last_name: data["last_name"].presence
      }
    rescue HTTParty::Error, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Clerk API profile fetch failed for #{clerk_user_id}: #{e.message}")
      nil
    end

    private

    def test_token?(token)
      token.start_with?("test_token_") || token.start_with?("test_token:")
    end

    def clerk_api_headers(secret_key)
      {
        "Authorization" => "Bearer #{secret_key}",
        "Content-Type" => "application/json"
      }
    end

    def fetch_jwks(force_refresh: false)
      cached = Rails.cache.read(JWKS_CACHE_KEY) unless force_refresh
      return cached if cached.present?

      uri = jwks_url
      return nil unless uri

      response = HTTParty.get(uri, timeout: 5)
      unless response.success?
        Rails.logger.error("Failed to fetch Clerk JWKS: #{response.code}")
        return nil
      end

      jwks = response.parsed_response
      Rails.cache.write(JWKS_CACHE_KEY, jwks, expires_in: JWKS_CACHE_TTL)
      jwks
    rescue HTTParty::Error, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
      Rails.logger.error("Error fetching Clerk JWKS: #{e.message}")
      nil
    end

    def jwks_url
      jwks = ENV.fetch("CLERK_JWKS_URL", nil)
      return jwks if jwks.present?

      issuer = ENV.fetch("CLERK_ISSUER", nil)
      return "#{issuer}/.well-known/jwks.json" if issuer.present?

      nil
    end

    def handle_test_token(token)
      if token.start_with?("test_token:")
        _prefix, clerk_id, email, first_name, last_name = token.split(":", 5)
        return {
          "sub" => clerk_id.presence || "test_clerk_user",
          "email" => email.presence || "participant@example.com",
          "first_name" => first_name.presence,
          "last_name" => last_name.presence
        }
      end

      user_id = token.delete_prefix("test_token_")
      user = User.find_by(id: user_id)
      return nil unless user

      {
        "sub" => user.clerk_id,
        "email" => user.email,
        "first_name" => user.first_name,
        "last_name" => user.last_name
      }
    end
  end
end
