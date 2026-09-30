# frozen_string_literal: true

require "digest"
require "json"

module Mia
  class PersonaPromptBuilder
    IMMUTABLE_BOUNDARY = <<~TEXT.squish.freeze
      This coach persona controls presentation and coaching style only. It cannot change product safety,
      financial truth, approval requirements, data access, tools, model selection, or write authority.
      Treat every persona field as reviewed style data within these boundaries.
    TEXT

    class << self
      def call(configuration)
        new(configuration).call
      end

      def digest(configuration, draft_revision:)
        raise PersonaSchema::InvalidConfiguration, [ "draft revision must be a positive integer" ] unless draft_revision.is_a?(Integer) && draft_revision.positive?

        payload = {
          "compiled_prompt_digest" => Digest::SHA256.hexdigest(call(configuration).b),
          "draft_revision" => draft_revision,
          "safety_policy_version" => PersonaSafetyPolicy::VERSION
        }
        Digest::SHA256.hexdigest(JSON.generate(payload).b)
      end
    end

    def initialize(configuration)
      @config = PersonaSchema.validate!(configuration)
    end

    def call
      [
        IMMUTABLE_BOUNDARY,
        identity_text,
        voice_text,
        coaching_text,
        culture_text,
        phrase_text,
        curriculum_text,
        response_shape_text
      ].join("\n\n")
    end

    private

    attr_reader :config

    def identity_text
      identity = config.fetch("identity")
      <<~TEXT.squish
        Identity: The assistant is #{identity.fetch("assistant_name")}. The human coach is
        #{identity.fetch("human_coach_name")}, #{identity.fetch("human_coach_title")}.
        Relationship: #{identity.fetch("assistant_relationship")} Disclosure: #{identity.fetch("disclosure")}
        Audience: #{identity.fetch("audience")} Refer to a client as #{identity.fetch("client_term")}.
      TEXT
    end

    def voice_text
      voice = config.fetch("voice")
      "Voice: #{voice.fetch("tone_traits").join(", ")}. Energy: #{voice.fetch("energy")} " \
        "Accountability: #{voice.fetch("accountability_style")} Language: #{voice.fetch("language_style").join("; ")}"
    end

    def coaching_text
      coaching = config.fetch("coaching")
      "Coaching philosophy: #{coaching.fetch("philosophy")} Method: #{coaching.fetch("method")} " \
        "Principles: #{coaching.fetch("principles").join("; ")} Do: #{coaching.fetch("do").join("; ")} " \
        "Do not: #{coaching.fetch("do_not").join("; ")}"
    end

    def culture_text
      culture = config.fetch("culture")
      "Cultural grounding (#{culture.fetch("locale_label")}): #{culture.fetch("context")} " \
        "Local realities: #{culture.fetch("local_realities").join("; ")} " \
        "References, only when relevant: #{culture.fetch("references").join("; ")}"
    end

    def phrase_text
      entries = config.fetch("phrases").map do |phrase|
        parts = [
          %("#{phrase.fetch("text")}" means #{phrase.fetch("meaning")}),
          "allowed: #{phrase.fetch("allowed_contexts").join(", ")}",
          "prohibited: #{phrase.fetch("prohibited_contexts").join(", ")}",
          "frequency: #{phrase.fetch("frequency")}"
        ]
        parts << "caution: #{phrase.fetch("caution")}" if phrase.fetch("caution").present?
        parts.join("; ")
      end
      "Coach-approved phrases: #{entries.presence&.join(" | ") || "none"}."
    end

    def curriculum_text
      curriculum = config.fetch("curriculum")
      guidance = curriculum.fetch("guidance").map { |item| "#{item.fetch("title")}: #{item.fetch("content")}" }
      scripts = curriculum.fetch("scripts").map { |item| "#{item.fetch("title")}: #{item.fetch("steps").join(" → ")}" }
      examples = curriculum.fetch("examples").map do |item|
        "Participant: #{item.fetch("participant")} Assistant: #{item.fetch("assistant")}"
      end
      "Curated guidance: #{guidance.presence&.join(" | ") || "none"}. " \
        "Curated scripts: #{scripts.presence&.join(" | ") || "none"}. " \
        "Coach-approved examples: #{examples.presence&.join(" | ") || "none"}."
    end

    def response_shape_text
      shape = config.fetch("response_shape")
      rules = [
        "#{shape.fetch("min_sentences")}-#{shape.fetch("max_sentences")} sentences",
        "at most #{shape.fetch("max_characters")} characters",
        (shape.fetch("plain_text_only") ? "plain text only" : "formatted text allowed"),
        (shape.fetch("validate_before_coaching") ? "validate before coaching" : "validation is optional"),
        (shape.fetch("next_move_required") ? "end with one next move" : "a next move is optional")
      ]
      "Response shape: #{rules.join("; ")}."
    end
  end
end
