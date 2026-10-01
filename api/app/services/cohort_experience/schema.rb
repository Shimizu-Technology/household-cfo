# frozen_string_literal: true

require "digest"
require "json"

module CohortExperience
  module Schema
    OPTIONAL_MODULES = %w[cfo_filter optionality].freeze
    DEFAULT_CONFIG = {
      "schema_version" => 1,
      "optional_modules" => OPTIONAL_MODULES.index_with(false)
    }.freeze
    LEGACY_CONFIG = {
      "schema_version" => 1,
      "optional_modules" => OPTIONAL_MODULES.index_with(true)
    }.freeze

    module_function

    def normalize(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      modules = input.fetch("optional_modules", {}).to_h.deep_stringify_keys
      {
        "schema_version" => Integer(input.fetch("schema_version", 1), exception: false),
        "optional_modules" => OPTIONAL_MODULES.index_with { |key| modules.fetch(key, false) }
      }
    end

    def errors(value)
      return [ "must be an object" ] unless value.respond_to?(:to_h)

      input = value.to_h.deep_stringify_keys
      result = []
      result << "must contain only schema_version and optional_modules" if (input.keys - %w[schema_version optional_modules]).any?
      result << "schema_version must be 1" unless input["schema_version"] == 1
      modules = input["optional_modules"]
      unless modules.is_a?(Hash)
        result << "optional_modules must be an object"
        return result
      end
      modules = modules.deep_stringify_keys
      result << "optional_modules contains an unsupported module" if (modules.keys - OPTIONAL_MODULES).any?
      OPTIONAL_MODULES.each do |key|
        result << "optional_modules.#{key} must be true or false" unless [ true, false ].include?(modules[key])
      end
      result
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(normalize(value)))
    end

    def preview_digest(value, draft_revision:)
      Digest::SHA256.hexdigest(JSON.generate({ "config" => normalize(value), "draft_revision" => draft_revision.to_i }))
    end
  end
end
