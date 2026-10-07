require_relative "workos_auth_test_support"

module AuthenticationTransitionTestSupport
  include WorkosAuthTestSupport
  CLERK_ISSUER = "https://clerk.fictional.test"

  def with_transition(values = {})
    keys = %w[CLERK_ISSUER CLERK_JWKS_URL CLERK_AUDIENCE CLERK_AUDIENCES RESEND_API_KEY MAILER_FROM_EMAIL]
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    with_workos({ "AUTH_PROVIDER" => "transition", "CLERK_ISSUER" => CLERK_ISSUER,
      "AUTH_PUBLIC_PROVIDER" => "clerk" }.merge(values)) do
      @clerk_key ||= OpenSSL::PKey::RSA.generate(2048)
      @clerk_jwk = JWT::JWK.new(@clerk_key, "clerk_current")
      yield
    end
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def clerk_signed_token(overrides = {}, key: @clerk_key, algorithm: "RS256")
    claims = { "iss" => CLERK_ISSUER, "sub" => "clerk_preserved", "exp" => 5.minutes.from_now.to_i,
      "email" => "workos@example.com", "first_name" => "Preserved", "last_name" => "Account" }.merge(overrides).compact
    JWT.encode(claims, key, algorithm, { "kid" => "clerk_current" })
  end

  def with_transition_http(workos_unavailable: false)
    stub_method(HTTParty, :get, lambda { |url, **_options|
      @workos_requests << url
      if url == "#{CLERK_ISSUER}/.well-known/jwks.json"
        WorkosResponse.new(200, { "keys" => [ @clerk_jwk.export.deep_stringify_keys ] })
      elsif url == "#{WorkosAuth.api_origin}/sso/jwks/#{WorkosAuth.client_id}"
        raise Timeout::Error if workos_unavailable
        WorkosResponse.new(200, { "keys" => [ @signing_jwk.export.deep_stringify_keys ] })
      elsif url == "#{WorkosAuth.api_origin}/user_management/users/user_test"
        WorkosResponse.new(200, workos_profile)
      else
        raise "Unexpected authentication HTTP request"
      end
    }) { yield }
  end
end
