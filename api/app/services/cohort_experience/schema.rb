# frozen_string_literal: true

require "digest"
require "json"

module CohortExperience
  module Schema
    OPTIONAL_MODULES = %w[cfo_filter optionality].freeze
    SUPPORTED_SCHEMA_VERSIONS = [ 1, 2, 3 ].freeze
    EXPERIENCE_MODES = %w[household_cfo savings_challenge].freeze
    DEFAULT_CONFIG = {
      "schema_version" => 1,
      "optional_modules" => OPTIONAL_MODULES.index_with(false).freeze
    }.freeze
    LEGACY_CONFIG = {
      "schema_version" => 1,
      "optional_modules" => OPTIONAL_MODULES.index_with(true).freeze
    }.freeze
    SAVINGS_CONFIG = {
      "schema_version" => 2,
      "experience_mode" => "savings_challenge",
      "optional_modules" => OPTIONAL_MODULES.index_with(false).freeze
    }.freeze
    PILOT_SAVINGS_CONFIG = SAVINGS_CONFIG.merge("schema_version" => 3).freeze

    module_function

    def normalize(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      modules = input.fetch("optional_modules", {}).to_h.deep_stringify_keys
      normalized = {
        "schema_version" => Integer(input.fetch("schema_version", 1), exception: false),
        "optional_modules" => OPTIONAL_MODULES.index_with { |key| modules.fetch(key, false) }
      }
      normalized["experience_mode"] = input["experience_mode"] if [ 2, 3 ].include?(normalized["schema_version"])
      normalized
    end

    def errors(value)
      return [ "must be an object" ] unless value.respond_to?(:to_h)

      input = value.to_h.deep_stringify_keys
      result = []
      allowed_keys = %w[schema_version optional_modules]
      allowed_keys += %w[experience_mode] if [ 2, 3 ].include?(input["schema_version"])
      result << "contains unsupported configuration fields" if (input.keys - allowed_keys).any?
      result << "schema_version must be 1, 2 or 3" unless SUPPORTED_SCHEMA_VERSIONS.include?(input["schema_version"])
      if [ 2, 3 ].include?(input["schema_version"]) && !EXPERIENCE_MODES.include?(input["experience_mode"])
        result << "experience_mode must be household_cfo or savings_challenge"
      end
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
