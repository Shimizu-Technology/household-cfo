require "base64"
require "digest"

module PlaidIntegration
  class TokenEncryptor
    class << self
      def encrypt(value)
        encryptor.encrypt_and_sign(value.to_s)
      end

      def decrypt(value)
        encryptor.decrypt_and_verify(value.to_s)
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise Error, "Stored bank connection credential could not be decrypted"
      end

      private

      def encryptor
        raw = ENV["PLAID_DATA_ENCRYPTION_KEY"].presence || test_key
        raise Error, "Plaid data encryption key is not configured" if raw.blank?

        key = Base64.strict_decode64(raw)
        raise Error, "Plaid data encryption key must be a base64-encoded 32-byte key" unless key.bytesize == 32

        ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
      rescue ArgumentError
        raise Error, "Plaid data encryption key must be a base64-encoded 32-byte key"
      end

      def test_key
        return "" unless Rails.env.test?

        Base64.strict_encode64(Digest::SHA256.digest("household-cfo-plaid-test-key"))
      end
    end
  end
end
