# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"

module ContentSources
  class UrlCipher
    CURRENT_VERSION = 1
    AAD_PREFIX = "household-cfo:content-source-url:v1"

    class ConfigurationError < StandardError; end
    class DecryptionError < StandardError; end

    class << self
      def current_version
        CURRENT_VERSION
      end

      def configured?
        validate_configuration!
      rescue ConfigurationError
        false
      end

      def validate_configuration!
        encryption_key(current_version)
        hmac_key(current_version)
        true
      end

      def encrypt(url)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        version = current_version
        cipher.key = encryption_key(version)
        iv = cipher.random_iv
        cipher.auth_data = aad(version)
        ciphertext = cipher.update(url.to_s) + cipher.final
        {
          ciphertext: Base64.strict_encode64(ciphertext),
          iv: Base64.strict_encode64(iv),
          auth_tag: Base64.strict_encode64(cipher.auth_tag),
          key_version: version
        }
      end

      def decrypt(payload)
        version = Integer(payload.fetch(:key_version))
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = encryption_key(version)
        cipher.iv = Base64.strict_decode64(payload.fetch(:iv))
        cipher.auth_tag = Base64.strict_decode64(payload.fetch(:auth_tag))
        cipher.auth_data = aad(version)
        cipher.update(Base64.strict_decode64(payload.fetch(:ciphertext))) + cipher.final
      rescue KeyError, ArgumentError, OpenSSL::Cipher::CipherError
        raise DecryptionError, "Stored source address could not be decrypted"
      end

      def identity(url, version: current_version)
        OpenSSL::HMAC.hexdigest("SHA256", hmac_key(version), url.to_s)
      end

      private

      def encryption_key(version)
        decode_key("CONTENT_SOURCE_URL_ENCRYPTION_KEY_V#{version}", test_key("encryption-v#{version}"))
      end

      def hmac_key(version)
        decode_key("CONTENT_SOURCE_URL_HMAC_KEY_V#{version}", test_key("identity-v#{version}"))
      end

      def decode_key(name, fallback)
        encoded = ENV[name].presence || fallback
        raise ConfigurationError, "Secure URL intake encryption is not configured" if encoded.blank?

        key = Base64.strict_decode64(encoded)
        raise ConfigurationError, "Secure URL intake key is invalid" unless key.bytesize == 32

        key
      rescue ArgumentError
        raise ConfigurationError, "Secure URL intake key is invalid"
      end

      def test_key(purpose)
        return "" unless Rails.env.test?

        Base64.strict_encode64(Digest::SHA256.digest("household-cfo-url-intake-#{purpose}"))
      end

      def aad(version)
        "#{AAD_PREFIX}:#{version}"
      end
    end
  end
end
