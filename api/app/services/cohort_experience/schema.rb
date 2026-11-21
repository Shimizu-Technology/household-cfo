# frozen_string_literal: true

require "digest"
require "json"

module CohortExperience
  module Schema
    OPTIONAL_MODULES = %w[cfo_filter optionality].freeze
    CONFIGURABLE_MODULES = %w[review budget profile statements wealth cfo_filter optionality].freeze
    MODULE_IDS = %w[home review ask_mia budget profile wealth cfo_filter optionality statements].freeze
    MODULE_DEFAULTS = CONFIGURABLE_MODULES.index_with { |key| !OPTIONAL_MODULES.include?(key) }.freeze
    SUPPORTED_SCHEMA_VERSIONS = [ 1, 2, 3, 4, 5 ].freeze
    CURRENT_SCHEMA_VERSION = 5
    MODE_SCHEMA_VERSIONS = [ 2, 3, 4, 5 ].freeze
    # Schema 4 added configurable tools and their order; schema 5 adds the coaching method.
    CONFIGURABLE_SCHEMA_VERSIONS = [ 4, 5 ].freeze
    EXPERIENCE_MODES = %w[household_cfo savings_challenge].freeze
    DEFAULT_CONFIG = {
      "schema_version" => 5,
      "experience_mode" => "household_cfo",
      "optional_modules" => MODULE_DEFAULTS,
      "module_order" => [].freeze,
      "method" => MethodSettings::DEFAULTS
    }.freeze
    # A corrupt published choice must never grant tools the coach may have disabled.
    RESTRICTED_CONFIG = DEFAULT_CONFIG.merge(
      "optional_modules" => CONFIGURABLE_MODULES.index_with(false).freeze
    ).freeze
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

    MODE_LABELS = {
      "household_cfo" => "Household CFO",
      "savings_challenge" => "90-day Savings Challenge"
    }.freeze

    module_function

    # The experience participants get for a config. Schema 1 predates modes and is the ordinary household experience.
    def mode_for(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      input["experience_mode"].presence_in(EXPERIENCE_MODES) || "household_cfo"
    end

    def mode_payload(value)
      mode = mode_for(value)
      { mode: mode, label: MODE_LABELS.fetch(mode) }
    end

    def normalize(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      modules = input.fetch("optional_modules", {}).to_h.deep_stringify_keys
      normalized = {
        "schema_version" => Integer(input.fetch("schema_version", 1), exception: false),
        "optional_modules" => module_keys(input).index_with { |key| modules.fetch(key, false) }
      }
      normalized["experience_mode"] = input["experience_mode"] if MODE_SCHEMA_VERSIONS.include?(normalized["schema_version"])
      normalized["module_order"] = input.fetch("module_order", []).dup if configurable?(normalized)
      normalized["method"] = MethodSettings.normalize(input.fetch("method", {})) if normalized["schema_version"] == 5
      normalized
    end

    def errors(value)
      return [ "must be an object" ] unless value.respond_to?(:to_h)

      input = value.to_h.deep_stringify_keys
      result = []
      allowed_keys = %w[schema_version optional_modules]
      allowed_keys += %w[experience_mode] if MODE_SCHEMA_VERSIONS.include?(input["schema_version"])
      allowed_keys += %w[module_order] if configurable?(input)
      allowed_keys += %w[method] if input["schema_version"] == 5
      result << "contains unsupported configuration fields" if (input.keys - allowed_keys).any?
      result << "schema_version must be 1, 2, 3, 4 or 5" unless SUPPORTED_SCHEMA_VERSIONS.include?(input["schema_version"])
      result.concat(MethodSettings.errors(input["method"])) if input["schema_version"] == 5
      if MODE_SCHEMA_VERSIONS.include?(input["schema_version"]) && !EXPERIENCE_MODES.include?(input["experience_mode"])
        result << "experience_mode must be household_cfo or savings_challenge"
      end
      modules = input["optional_modules"]
      unless modules.is_a?(Hash)
        result << "optional_modules must be an object"
        return result
      end
      modules = modules.deep_stringify_keys
      result << "optional_modules contains an unsupported module" if (modules.keys - module_keys(input)).any?
      module_keys(input).each do |key|
        result << "optional_modules.#{key} must be true or false" unless [ true, false ].include?(modules[key])
      end
      if configurable?(input)
        order = input.fetch("module_order", [])
        unless order.is_a?(Array) && order.all? { |id| MODULE_IDS.include?(id) } && order.uniq == order
          result << "module_order must contain unique supported module IDs"
        end
      end
      result
    end

    def module_keys(input)
      configurable?(input) ? CONFIGURABLE_MODULES : OPTIONAL_MODULES
    end

    def configurable?(input)
      CONFIGURABLE_SCHEMA_VERSIONS.include?(input["schema_version"])
    end

    # The coaching method a config gives participants. Schemas before 5 read as the defaults.
    def method_for(value)
      input = value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
      return MethodSettings.defaults unless input["schema_version"] == 5 && MethodSettings.errors(input["method"]).empty?

      MethodSettings.resolve(input["method"])
    end

    # Upgrading a draft is explicit; historical config bytes and digests stay unchanged.
    def upgrade(value)
      input = normalize(value)
      return input if input["schema_version"] == CURRENT_SCHEMA_VERSION

      {
        "schema_version" => CURRENT_SCHEMA_VERSION,
        "experience_mode" => mode_for(input),
        "optional_modules" => configurable?(input) ? input.fetch("optional_modules") : MODULE_DEFAULTS.merge(input.fetch("optional_modules")),
        "module_order" => input.fetch("module_order", []),
        "method" => MethodSettings.defaults
      }
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(normalize(value)))
    end

    def preview_digest(value, draft_revision:)
      Digest::SHA256.hexdigest(JSON.generate({ "config" => normalize(value), "draft_revision" => draft_revision.to_i }))
    end
  end
end
