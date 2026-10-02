# frozen_string_literal: true

require "digest"
require "json"

module Mia
  class PersonaRuntimeCompatibility
    LEGACY_CONFIG_VERSION = 1
    LEGACY_COACH_CAPTURE_ROLE = "coach"
    PHRASE_AUTHORING_KEYS = %w[text meaning allowed_contexts prohibited_contexts frequency caution].freeze
    PHRASE_PROVENANCE_KEYS = %w[artifact_id provenance source_user_id source_role_at_capture fingerprint].freeze
    SEALED_PHRASE_KEYS = (PHRASE_AUTHORING_KEYS + PHRASE_PROVENANCE_KEYS).freeze

    class << self
      def call(version)
        verify_published_version!(version)
        raw_config = PersonaSchema.normalize(version.config)
        verify_published_digest!(version, raw_config)
        verify_phrase_manifest!(version)
        return raw_config unless compatible_legacy_version?(version, raw_config)

        config = normalize_voice(raw_config.deep_dup)
        seal_phrases(config, version: version)
      end

      def legacy_digest(configuration)
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(PersonaSchema.normalize(configuration))).b)
      end

      private

      def verify_published_version!(version)
        return if version.is_a?(CoachPersonaVersion) && version.persisted? && version.sealed?

        raise PersonaSchema::InvalidConfiguration.new([ "runtime persona version must be a persisted, sealed publication" ])
      end

      def compatible_legacy_version?(version, config)
        config["version"] == LEGACY_CONFIG_VERSION
      end

      def verify_published_digest!(version, config)
        valid = version.config_digest.to_s.match?(/\A[0-9a-f]{64}\z/) &&
          ActiveSupport::SecurityUtils.secure_compare(version.config_digest, legacy_digest(config))
        return if valid

        raise PersonaSchema::InvalidConfiguration.new([ "published persona config digest does not match stored configuration" ])
      end

      def verify_phrase_manifest!(version)
        return if version.phrase_manifest_valid?

        raise PersonaSchema::InvalidConfiguration.new([ "published persona phrase manifest failed integrity validation" ])
      end

      def seal_phrases(config, version:)
        phrases = config["phrases"]
        return config unless phrases.is_a?(Array)

        owner_id = version.coach_persona.created_by_user_id
        config["phrases"] = phrases.each_with_index.map do |raw_phrase, index|
          seal_phrase(raw_phrase, version:, index:, owner_id:)
        end
        config
      end

      def seal_phrase(raw_phrase, version:, index:, owner_id:)
        return raw_phrase unless raw_phrase.is_a?(Hash)

        phrase = raw_phrase.deep_stringify_keys
        return phrase if exact_sealed_phrase?(phrase)
        return phrase unless exact_legacy_phrase?(phrase)

        artifact = phrase.slice(*PHRASE_AUTHORING_KEYS).merge(
          "artifact_id" => deterministic_artifact_id(version, index),
          "provenance" => "coach_authored",
          "source_user_id" => owner_id,
          # The legacy authoring format was available only in Coach Studio. Use a
          # stable historical capture value rather than the owner's mutable role.
          "source_role_at_capture" => LEGACY_COACH_CAPTURE_ROLE
        )
        artifact["fingerprint"] = PersonaSchema.artifact_fingerprint(artifact)
        artifact
      end

      def exact_sealed_phrase?(phrase)
        phrase.keys.sort == SEALED_PHRASE_KEYS.sort
      end

      def exact_legacy_phrase?(phrase)
        phrase.keys.sort == PHRASE_AUTHORING_KEYS.sort
      end

      def deterministic_artifact_id(version, index)
        hex = Digest::SHA256.hexdigest("legacy-persona-phrase:#{version.id}:#{index}:#{version.config_digest}")
        hex[12] = "4"
        hex[16] = "8"
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end

      def normalize_voice(config)
        voice = config["voice"]
        return config unless voice.is_a?(Hash)

        config["voice"] = {
          "tone_traits" => normalized_tones(voice["tone_traits"]),
          "energy" => normalized_energy(voice["energy"]),
          "accountability_style" => normalized_accountability(voice["accountability_style"]),
          "language_style" => normalized_language(voice["language_style"])
        }
        config
      end

      def normalized_tones(value)
        source = Array(value).join(" ").downcase
        selected = PersonaSchema::TONE_TRAITS.select { |trait| source.match?(/\b#{Regexp.escape(trait)}\b/) }
        selected << "warm" if source.match?(/\b(?:empathetic|friendly|welcoming)\b/)
        selected << "practical" if source.match?(/\bgrounded\b/)
        selected << "lighthearted" if source.match?(/\b(?:funny|humorous|playful)\b/)
        selected << "formal" if source.match?(/\bprofessional\b/)
        selected << "calm" if source.match?(/\bmeasured\b/)
        selected.uniq.presence || %w[warm direct respectful]
      end

      def normalized_energy(value)
        source = value.to_s
        return source if PersonaSchema::ENERGY_STYLES.include?(source)
        return "Quiet and unhurried." if source.match?(/\b(?:quiet|unhurried|slow)\b/i)
        if source.match?(/\bcalm\b/i)
          return "Calm, clear, and concise." if source.match?(/\b(?:direct|clear|concise|exact)\b/i)

          return "Calm and focused."
        end
        return "Direct and energetic." if source.match?(/\b(?:direct|energetic|high.energy)\b/i)
        return "Warm and encouraging." if source.match?(/\b(?:warm|encourag)\w*/i)
        return "Steady and reassuring." if source.match?(/\b(?:steady|reassur|confiden)\w*/i)
        return "Calm, clear, and concise." if source.match?(/\b(?:clear|concise|exact)\b/i)

        "Calm and focused."
      end

      def normalized_accountability(value)
        source = value.to_s
        return source if PersonaSchema::ACCOUNTABILITY_STYLES.include?(source)
        return PersonaSchema::ACCOUNTABILITY_STYLES[1] if source.match?(/\b(?:reflect|question|ask)\w*/i)
        return PersonaSchema::ACCOUNTABILITY_STYLES[3] if source.match?(/\b(?:gentle|support)\w*/i)
        return PersonaSchema::ACCOUNTABILITY_STYLES[4] if source.match?(/\b(?:firm|specific)\b/i)
        return PersonaSchema::ACCOUNTABILITY_STYLES[2] if source.match?(/\b(?:direct|trade.?off)\w*/i)

        PersonaSchema::ACCOUNTABILITY_STYLES[0]
      end

      def normalized_language(value)
        values = Array(value).map(&:to_s)
        return values if values.present? && values.all? { |item| PersonaSchema::LANGUAGE_STYLES.include?(item) }

        source = values.join(" ")
        selected = []
        selected << PersonaSchema::LANGUAGE_STYLES[0] if source.match?(/\b(?:plain|simple)\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[1] if source.match?(/\b(?:concrete|next step|actionable)\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[2] if source.match?(/\b(?:short sentences?|concrete questions?)\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[3] if source.match?(/\bconversational\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[4] if source.match?(/\b(?:professional|formal)\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[5] if source.match?(/\b(?:humou?r|lighthearted|joke)\w*/i)
        selected << PersonaSchema::LANGUAGE_STYLES[6] if source.match?(/\b(?:concise|brief|jargon)\b/i)
        selected << PersonaSchema::LANGUAGE_STYLES[7] if source.match?(/\b(?:explain|define).{0,30}\b(?:term|jargon)\w*/i)
        selected.uniq.presence || PersonaSchema::LANGUAGE_STYLES.first(2)
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
        when Array
          value.map { |child| canonicalize(child) }
        else
          value
        end
      end
    end
  end
end
