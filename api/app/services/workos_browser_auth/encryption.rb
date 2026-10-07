module WorkosBrowserAuth
  class Encryption
    PURPOSE = "workos-browser-credentials-v1"
    PKCE_PURPOSE = "workos-browser-pkce-v1"

    def self.encrypt(value, purpose: PURPOSE)
      encryptor(purpose).encrypt_and_sign(value, purpose: purpose)
    end

    def self.decrypt(value, purpose: PURPOSE)
      result = encryptor(purpose).decrypt_and_verify(value, purpose: purpose)
      raise WorkosAuth::InvalidToken, "Sign in again to continue" if result.nil?
      result
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      raise WorkosAuth::InvalidToken, "Sign in again to continue"
    end

    def self.encryptor(purpose)
      raise WorkosAuth::Unavailable, "Secure sessions are not configured" if Rails.application.secret_key_base.to_s.bytesize < 32
      key = Rails.application.key_generator.generate_key(purpose, 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON)
    end
    private_class_method :encryptor
  end
end
