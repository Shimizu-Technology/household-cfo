require "digest"

module PlaidIntegration
  class WebhookVerifier
    MAX_AGE = 5.minutes

    def initialize(token:, body:)
      @token = token.to_s
      @body = body.to_s
    end

    def verify!
      raise Error, "Missing Plaid webhook signature" if token.blank?

      header = JWT.decode(token, nil, false).last
      raise Error, "Invalid Plaid webhook signature" unless header["alg"] == "ES256" && header["kid"].present?

      key_data = Rails.cache.fetch("plaid:webhook-jwk:#{Digest::SHA256.hexdigest(header.fetch('kid'))}", expires_in: MAX_AGE) do
        Client.safely do |client|
          client.webhook_verification_key_get(Plaid::WebhookVerificationKeyGetRequest.new(key_id: header.fetch("kid"))).key.to_hash
        end
      end
      jwk = JWT::JWK.import(key_data)
      payload = JWT.decode(token, jwk.public_key, true, algorithm: "ES256").first
      issued_at = Time.at(Integer(payload.fetch("iat")))
      raise Error, "Expired Plaid webhook signature" if issued_at < MAX_AGE.ago || issued_at > 1.minute.from_now
      raise Error, "Plaid webhook body did not match its signature" unless ActiveSupport::SecurityUtils.secure_compare(payload.fetch("request_body_sha256"), Digest::SHA256.hexdigest(body))

      true
    rescue JWT::DecodeError, JWT::JWKError, KeyError, ArgumentError
      raise Error, "Invalid Plaid webhook signature"
    end

    private

    attr_reader :token, :body
  end
end
