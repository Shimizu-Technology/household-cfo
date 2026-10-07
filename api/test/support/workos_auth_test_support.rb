module WorkosAuthTestSupport
  WORKOS_ENV_KEYS = %w[AUTH_PROVIDER AUTH_PUBLIC_PROVIDER WORKOS_CLIENT_ID WORKOS_API_KEY WORKOS_ISSUER WORKOS_API_HOSTNAME WORKOS_INVITATION_EMAIL_DELIVERY WORKOS_INVITATION_EMAILS_DISABLED].freeze
  WorkosResponse = Struct.new(:code, :parsed_response) do
    def success?
      code >= 200 && code < 300
    end
  end

  def stub_method(target, method, replacement)
    singleton = target.singleton_class
    original = target.method(method)
    singleton.define_method(method) do |*args, **options, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **options, &block) : replacement
    end
    yield
  ensure
    singleton.send(:remove_method, method)
    singleton.define_method(method, original)
  end

  def with_workos(values = {})
    previous = WORKOS_ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    WORKOS_ENV_KEYS.each { |key| ENV.delete(key) }
    { "AUTH_PROVIDER" => "workos", "WORKOS_CLIENT_ID" => "client_cfo", "WORKOS_API_KEY" => "test-secret" }.merge(values).each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    @signing_key ||= OpenSSL::PKey::RSA.generate(2048)
    @signing_jwk = JWT::JWK.new(@signing_key, "current")
    @workos_requests = []
    yield
  ensure
    Rails.cache = cache
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def workos_token(overrides = {}, key: @signing_key, kid: "current", algorithm: "RS256")
    claims = { "iss" => WorkosAuth.issuer, "sub" => "user_test", "sid" => "session_test",
      "client_id" => "client_cfo", "exp" => 5.minutes.from_now.to_i, "iat" => Time.current.to_i }.merge(overrides)
    claims.compact!
    JWT.encode(claims, key, algorithm, { "kid" => kid })
  end

  def with_workos_http(profile: workos_profile, keys: nil, &block)
    handler = lambda do |url, **options|
      @workos_requests << [ url, options ]
      if url.include?("/sso/jwks/")
        WorkosResponse.new(200, { "keys" => (keys || [ @signing_jwk.export ]).map(&:deep_stringify_keys) })
      elsif url.end_with?("/user_management/users/user_test")
        WorkosResponse.new(200, profile)
      else
        raise "Unexpected WorkOS request"
      end
    end
    stub_method(HTTParty, :get, handler, &block)
  end

  def workos_profile
    { "id" => "user_test", "email" => "workos@example.com", "email_verified" => true,
      "first_name" => "WorkOS", "last_name" => "User" }
  end
end
