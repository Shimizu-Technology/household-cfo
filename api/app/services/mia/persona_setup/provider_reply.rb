# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Tolerate presentation wrappers, never ambiguous alternative objects. This
    # only decodes; each caller still validates its complete schema and model.
    class ProviderReply
      class Malformed < StandardError; end
      TRANSPORT_ERRORS = [ Timeout::Error, SocketError, SystemCallError, EOFError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError ].freeze

      def self.with_retry
        attempts = 0
        begin
          attempts += 1
          yield
        rescue Malformed, JSON::ParserError, *TRANSPORT_ERRORS => error
          Rails.logger.info({ event: "mia.persona_setup.retry", error: error.class.name, attempt: attempts }.to_json)
          retry if attempts < 2
          raise
        end
      end

      def self.object(content)
        text = content.to_s.strip
        begin
          parsed = JSON.parse(text)
          raise Malformed, "Expected an object" unless parsed.is_a?(Hash)
          return parsed
        rescue JSON::ParserError
          # Some providers return prose / markdown / tool-like markup around
          # the object. Scan balanced JSON, respecting quoted braces/escapes.
        end
        objects = []
        start = nil
        depth = 0
        quoted = false
        escaped = false
        text.each_char.with_index do |char, index|
          if start.nil?
            next unless char == "{"
            start = index
          end
          if quoted
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == '"'
              quoted = false
            end
          elsif char == '"'
            quoted = true
          elsif char == "{"
            depth += 1
          elsif char == "}"
            depth -= 1
            if depth.zero?
              objects << JSON.parse(text[start..index])
              start = nil
            end
          end
        end
        raise Malformed, "Expected exactly one complete object" unless start.nil? && objects.one? && objects.first.is_a?(Hash)
        # An array of objects is not a presentation wrapper around one object.
        raise Malformed, "Expected an object, not an array" if text.start_with?("[")

        objects.first
      end
    end
  end
end
