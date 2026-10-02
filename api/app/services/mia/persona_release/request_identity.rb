# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    module RequestIdentity
      KEY_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,99}\z/

      module_function

      def normalize!(value)
        key = value.to_s.strip
        raise ArgumentError, "A stable request_id is required" unless key.match?(KEY_PATTERN)

        key
      end

      def fingerprint(payload)
        Digest::SHA256.hexdigest(JSON.generate(PhraseManifest.canonicalize(payload)).b)
      end
    end
  end
end
