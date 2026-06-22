require "yaml"

module Mia
  class Persona
    DEFAULT_ID = "mia_household_cfo_guam".freeze
    CONFIG_PATH = Rails.root.join("config", "mia_personas.yml")

    class << self
      def default
        configured_default = config.fetch("default", DEFAULT_ID)
        find(ENV.fetch("MIA_PERSONA_ID", configured_default))
      end

      def find(id)
        personas = config.fetch("personas")
        new(id, personas.fetch(id))
      rescue KeyError
        new(DEFAULT_ID, personas.fetch(DEFAULT_ID))
      end

      def reset_cache!
        @config = nil
      end

      private

      def config
        @config ||= YAML.safe_load(CONFIG_PATH.read, permitted_classes: [], aliases: false).fetch("mia_personas")
      end
    end

    attr_reader :id, :data

    def initialize(id, data)
      @id = id
      @data = data.deep_stringify_keys
    end

    def name
      data.fetch("name")
    end

    def role
      data.fetch("role")
    end

    def voice_summary
      data.fetch("voice").fetch("summary")
    end

    def disclaimer
      "#{name} is a coaching and education tool powered by VERA. She does not replace legal, tax, investment, accounting, therapeutic, or financial advice."
    end

    def fallback_response(key)
      data.fetch("fallbacks").fetch(key.to_s)
    end

    def system_prompt
      <<~PROMPT.squish
        Coach persona template: #{id}.
        Identity: #{name}, #{data.fetch("acronym")}, is the #{role} inside #{data.fetch("product")}.
        Audience: #{data.fetch("audience")}
        Transformation promise: #{data.fetch("transformation_promise")}
        Voice: #{voice_summary}.
        Coaching method: #{coaching_method_prompt}
        Cultural persona: #{culture_pack_prompt}
        Response shape: #{response_shape_prompt}
        Phrase library: #{phrase_library_prompt}
        Do not: #{data.fetch("do_not").join("; ")}.
      PROMPT
    end

    private

    def coaching_method_prompt
      method = data.fetch("coaching_method")
      "#{method.fetch("name")} (#{method.fetch("id")}): #{method.fetch("instructions").join(" ")}"
    end

    def culture_pack_prompt
      culture = data.fetch("culture_pack")
      "#{culture.fetch("identity")} (#{culture.fetch("id")}): #{culture.fetch("instructions").join(" ")}"
    end

    def response_shape_prompt
      shape = data.fetch("response_shape")
      rules = []
      rules << "#{shape.fetch("min_sentences")}-#{shape.fetch("max_sentences")} sentences"
      rules << "plain text only" if shape.fetch("plain_text_only")
      rules << "no markdown" unless shape.fetch("markdown_allowed")
      rules << "validate before coaching" if shape.fetch("validate_before_coaching")
      rules << "one next move is required" if shape.fetch("next_move_required")
      rules.join("; ")
    end

    def phrase_library_prompt
      data.fetch("phrase_library").map do |_key, entry|
        parts = [ "#{entry.fetch("phrase")} means/use: #{entry.fetch("use")}" ]
        parts << "frequency: #{entry.fetch("frequency")}" if entry["frequency"].present?
        parts << "caution: #{entry.fetch("caution")}" if entry["caution"].present?
        parts.join(", ")
      end.join("; ")
    end
  end
end
