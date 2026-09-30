# frozen_string_literal: true

module HouseholdFinance
  module PersonaVersionedContinuity
    UNFILTERED_PERSONA_VERSION = Object.new.freeze
    ASSISTANT_PERSONA_CONTEXT_KEY = "assistant_persona_context_id"
    ASSISTANT_PERSONA_VERSION_KEY = "assistant_persona_version_id"
    ASSISTANT_DERIVED_KEYS = %w[latest_mia_summary next_move].freeze

    module_function

    def filter_topic(value, persona_context_id:)
      topic = value.to_h.deep_stringify_keys
      return topic if persona_context_id.equal?(UNFILTERED_PERSONA_VERSION)
      return topic if assistant_context_matches?(topic, persona_context_id)

      topic.except(ASSISTANT_PERSONA_CONTEXT_KEY, ASSISTANT_PERSONA_VERSION_KEY, *ASSISTANT_DERIVED_KEYS)
    end

    def stamp_assistant_context(value, persona_context_id:, persona_version_id: nil)
      topic = value.to_h.deep_stringify_keys
      return topic unless ASSISTANT_DERIVED_KEYS.any? { |key| topic[key].present? }
      return topic if persona_context_id.equal?(UNFILTERED_PERSONA_VERSION)

      stamped = topic.merge(ASSISTANT_PERSONA_CONTEXT_KEY => persona_context_id.to_s)
      return stamped.merge(ASSISTANT_PERSONA_VERSION_KEY => persona_version_id) if persona_version_id.present?

      stamped.except(ASSISTANT_PERSONA_VERSION_KEY)
    end

    def filtering?(persona_context_id)
      !persona_context_id.equal?(UNFILTERED_PERSONA_VERSION)
    end

    def assistant_context_matches?(topic, persona_context_id)
      topic[ASSISTANT_PERSONA_CONTEXT_KEY].to_s == persona_context_id.to_s
    end
    private_class_method :assistant_context_matches?
  end
end
