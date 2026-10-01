require "digest"

module HouseholdFinance
  module Operations
    class PreparedOperation
      ATTRIBUTES = %w[
        household_id operation_key operation_version normalized_input subject before_snapshot
        predicted_after_snapshot before_fingerprint
      ].freeze

      attr_reader(*ATTRIBUTES.map(&:to_sym))

      def initialize(**attributes)
        values = attributes.stringify_keys
        ATTRIBUTES.each { |attribute| instance_variable_set("@#{attribute}", values.fetch(attribute)) }
      end

      def as_json(*)
        ATTRIBUTES.index_with { |attribute| public_send(attribute) }
      end

      def fingerprint
        self.class.fingerprint(as_json)
      end

      def self.from_hash(value)
        new(**value.to_h.slice(*ATTRIBUTES))
      end

      def self.fingerprint(value)
        Digest::SHA256.hexdigest(JSON.generate(deep_sort(value)))
      end

      def self.deep_sort(value)
        case value
        when Hash then value.stringify_keys.sort.to_h.transform_values { |item| deep_sort(item) }
        when Array then value.map { |item| deep_sort(item) }
        else value
        end
      end
    end
  end
end
