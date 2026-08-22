require "test_helper"
require "ostruct"
require "openssl"

class PlaidIntegrationWebhookVerifierTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @body = { webhook_type: "TRANSACTIONS", webhook_code: "SYNC_UPDATES_AVAILABLE", item_id: "item-test" }.to_json
    @key = OpenSSL::PKey::EC.generate("prime256v1")
    @jwk = JWT::JWK.new(@key)
    key_data = @jwk.export
    key_object = Object.new
    key_object.define_singleton_method(:to_hash) { key_data }
    @fake = Object.new
    @fake.define_singleton_method(:webhook_verification_key_get) { |_request| OpenStruct.new(key: key_object) }
  end

  test "accepts a current Plaid signature whose body hash matches" do
    assert with_client(@fake) { PlaidIntegration::WebhookVerifier.new(token: token_for(@body), body: @body).verify! }
  end

  test "rejects a signature when the request body changes" do
    error = with_client(@fake) do
      assert_raises(PlaidIntegration::Error) do
        PlaidIntegration::WebhookVerifier.new(token: token_for(@body), body: "{}").verify!
      end
    end

    assert_equal "Plaid webhook body did not match its signature", error.message
  end

  test "rejects an expired signature" do
    error = with_client(@fake) do
      assert_raises(PlaidIntegration::Error) do
        PlaidIntegration::WebhookVerifier.new(token: token_for(@body, issued_at: 6.minutes.ago), body: @body).verify!
      end
    end

    assert_equal "Expired Plaid webhook signature", error.message
  end

  private

  def token_for(body, issued_at: Time.current)
    JWT.encode(
      { "iat" => issued_at.to_i, "request_body_sha256" => Digest::SHA256.hexdigest(body) },
      @key,
      "ES256",
      { "kid" => @jwk.kid }
    )
  end

  def with_client(fake)
    singleton = class << PlaidIntegration::Client; self; end
    original = PlaidIntegration::Client.method(:safely)
    singleton.define_method(:safely) { |&block| block.call(fake) }
    yield
  ensure
    singleton.define_method(:safely, original)
  end
end
