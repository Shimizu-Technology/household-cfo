# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Mia
  class PersonaSchema
    MAX_AUTHORING_BYTES = 32_768
    MAX_BYTES = 40_960
    FREQUENCIES = %w[very_rare rare sparing as_needed].freeze
    PHRASE_CONTEXTS = %w[greeting verified_milestone emotional_support repeated_pattern routine general crisis].freeze
    PHRASE_PROVENANCE = %w[coach_authored participant_supplied].freeze
    PHRASE_SOURCE_ROLES = %w[admin coach participant].freeze
    ARTIFACT_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    TONE_TRAITS = %w[
      warm direct respectful calm encouraging candid patient concise practical reassuring lighthearted formal clear unhurried
    ].freeze
    ENERGY_STYLES = [
      "Calm and focused.",
      "Calm, clear, and concise.",
      "Steady and reassuring.",
      "Warm and encouraging.",
      "Direct and energetic.",
      "Quiet and unhurried."
    ].freeze
    ACCOUNTABILITY_STYLES = [
      "Name choices and patterns clearly while protecting the participant's dignity.",
      "Ask reflective questions before naming a pattern.",
      "Be direct about tradeoffs while staying respectful.",
      "Use gentle accountability and one practical next step.",
      "Keep accountability firm, calm, and specific."
    ].freeze
    LANGUAGE_STYLES = [
      "Use plain language.",
      "Keep the next step concrete.",
      "Use short sentences and concrete questions.",
      "Prefer conversational language.",
      "Keep the tone professional and formal.",
      "Use light humor only when the situation is not sensitive.",
      "Be concise and avoid unnecessary jargon.",
      "Explain unfamiliar financial terms briefly."
    ].freeze
    TOP_LEVEL_KEYS = %w[version identity voice coaching culture phrases curriculum response_shape].freeze

    class InvalidConfiguration < ArgumentError
      attr_reader :errors

      def initialize(errors)
        @errors = errors.freeze
        super(errors.join(", "))
      end
    end

    class << self
      def default_configuration(assistant_name:, human_coach_name:, human_coach_title: "Financial coach")
        configuration = {
          version: 1,
          identity: {
            assistant_name: assistant_name,
            human_coach_name: human_coach_name,
            human_coach_title: human_coach_title,
            assistant_relationship: "A digital coaching assistant that applies the human coach's approved teaching without impersonating the human coach.",
            disclosure: "Be clear that this is a digital assistant guided by the human coach's published approach.",
            audience: "People participating in the human coach's financial education program.",
            client_term: "participant"
          },
          voice: {
            tone_traits: [ "warm", "direct", "respectful" ],
            energy: "Calm and focused.",
            accountability_style: "Name choices and patterns clearly while protecting the participant's dignity.",
            language_style: [ "Use plain language.", "Keep the next step concrete." ]
          },
          coaching: {
            philosophy: "Help the participant understand the decision and make one practical move at a time.",
            method: "Answer the direct question, explain the reasoning, and identify one useful next step.",
            principles: [ "Use the participant's confirmed information.", "Coach decisions and patterns without shame." ],
            do: [],
            do_not: []
          },
          culture: {
            locale_label: "No locale selected",
            context: "Use only cultural and community context explicitly approved by the human coach.",
            local_realities: [],
            references: []
          },
          phrases: [],
          curriculum: { guidance: [], scripts: [], examples: [] },
          response_shape: {
            min_sentences: 2,
            max_sentences: 5,
            max_characters: 1_500,
            plain_text_only: true,
            validate_before_coaching: true,
            next_move_required: true
          }
        }
        validate!(configuration)
      end

      def validate!(configuration)
        normalized = normalize(configuration)
        PersonaSafetyPolicy.validate!(normalized)
        errors = validate_configuration(normalized)
        raise InvalidConfiguration, errors if errors.any?

        normalized
      rescue PersonaSafetyPolicy::UnsafeConfiguration => error
        raise InvalidConfiguration, error.errors
      end

      def valid?(configuration)
        validate!(configuration)
        true
      rescue InvalidConfiguration
        false
      end

      def errors(configuration)
        validate!(configuration)
        []
      rescue InvalidConfiguration => error
        error.errors
      end

      def canonical_json(configuration)
        JSON.generate(canonicalize(validate!(configuration)))
      end

      def digest(configuration)
        Digest::SHA256.hexdigest(canonical_json(configuration).b)
      end

      def prepare_draft_artifacts(configuration, source_user_id:, source_role_at_capture: "coach", existing_configuration: nil, allow_coach_artifact_edits: true)
        config = normalize(configuration).deep_dup
        existing_artifacts = Array(normalize(existing_configuration).to_h["phrases"]).index_by do |phrase|
          phrase["artifact_id"] if phrase.is_a?(Hash) && phrase["artifact_id"].present?
        end.compact
        unless allow_coach_artifact_edits
          submitted_ids = Array(config["phrases"]).filter_map do |phrase|
            phrase["artifact_id"] if phrase.is_a?(Hash) && phrase["artifact_id"].present?
          end
          unless submitted_ids == existing_artifacts.keys
            raise InvalidConfiguration,
              [ "$.phrases artifact collection can be changed only by a coach workspace editor" ]
          end
        end
        config["phrases"] = Array(config["phrases"]).each_with_index.map do |phrase, index|
          next phrase unless phrase.is_a?(Hash)

          existing = existing_artifacts[phrase["artifact_id"]]
          if existing.present?
            unless phrase["provenance"] == existing["provenance"]
              raise InvalidConfiguration,
                [ "$.phrases[#{index}] provenance cannot change for an existing phrase artifact" ]
            end

            if existing["provenance"] == "participant_supplied"
              unless artifacts_match?(phrase, existing)
                raise InvalidConfiguration,
                  [ "$.phrases[#{index}] participant-supplied artifact must be imported by a trusted participant-language workflow" ]
              end
              next existing
            end

            next existing if artifacts_match?(phrase, existing)

            unless allow_coach_artifact_edits
              raise InvalidConfiguration,
                [ "$.phrases[#{index}] coach-authored artifact can be edited only by a coach workspace editor" ]
            end

            next build_phrase_artifact(
              phrase,
              artifact_id: existing.fetch("artifact_id"),
              provenance: "coach_authored",
              source_user_id: source_user_id,
              source_role_at_capture: existing.fetch("source_role_at_capture")
            )
          end

          if phrase["provenance"] == "participant_supplied"
            raise InvalidConfiguration,
              [ "$.phrases[#{index}] participant-supplied artifact must be imported by a trusted participant-language workflow" ]
          end
          unless allow_coach_artifact_edits
            raise InvalidConfiguration,
              [ "$.phrases[#{index}] coach-authored artifact can be added only by a coach workspace editor" ]
          end

          build_phrase_artifact(
            phrase,
            artifact_id: SecureRandom.uuid,
            provenance: "coach_authored",
            source_user_id: source_user_id,
            source_role_at_capture: source_role_at_capture
          )
        end
        config
      end

      def build_phrase_artifact(attributes, artifact_id: SecureRandom.uuid, provenance: "coach_authored", source_user_id:, source_role_at_capture: nil)
        normalized = normalize(attributes)
        captured_role = source_role_at_capture.presence || (provenance.to_s == "participant_supplied" ? "participant" : "coach")
        artifact = {
          "artifact_id" => artifact_id.to_s,
          "provenance" => provenance.to_s,
          "source_user_id" => Integer(source_user_id, exception: false),
          "source_role_at_capture" => captured_role.to_s,
          "text" => normalized["text"],
          "meaning" => normalized["meaning"],
          "allowed_contexts" => normalized["allowed_contexts"],
          "prohibited_contexts" => normalized["prohibited_contexts"],
          "frequency" => normalized["frequency"],
          "caution" => normalized["caution"]
        }
        artifact["fingerprint"] = artifact_fingerprint(artifact)
        artifact
      end

      def artifact_fingerprint(artifact)
        normalized = normalize(artifact).except("fingerprint")
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(normalized)).b)
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = normalize(child) }
        when Array
          value.map { |child| normalize(child) }
        else
          value
        end
      end

      private

      def artifacts_match?(left, right)
        left_json = JSON.generate(canonicalize(left))
        right_json = JSON.generate(canonicalize(right))
        ActiveSupport::SecurityUtils.secure_compare(left_json, right_json)
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

      def validate_configuration(config)
        errors = []
        return [ "$ must be an object" ] unless config.is_a?(Hash)

        exact_keys(config, TOP_LEVEL_KEYS, "$", errors)
        errors << "$.version must equal 1" unless config["version"] == 1
        validate_identity(config["identity"], errors)
        validate_voice(config["voice"], errors)
        validate_coaching(config["coaching"], errors)
        validate_culture(config["culture"], errors)
        validate_phrases(config["phrases"], errors)
        validate_curriculum(config["curriculum"], errors)
        validate_response_shape(config["response_shape"], errors)

        byte_size = JSON.generate(config).bytesize
        errors << "$ exceeds #{MAX_BYTES} bytes" if byte_size > MAX_BYTES
        authoring_byte_size = JSON.generate(authoring_configuration(config)).bytesize
        errors << "$ authored content exceeds #{MAX_AUTHORING_BYTES} bytes" if authoring_byte_size > MAX_AUTHORING_BYTES
        errors.first(40)
      rescue JSON::GeneratorError
        [ "$ must contain only JSON-compatible values" ]
      end

      def validate_identity(value, errors)
        path = "$.identity"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[assistant_name human_coach_name human_coach_title assistant_relationship disclosure audience client_term], path, errors)
        bounded_string(value["assistant_name"], "#{path}.assistant_name", errors, 80)
        bounded_string(value["human_coach_name"], "#{path}.human_coach_name", errors, 120)
        bounded_string(value["human_coach_title"], "#{path}.human_coach_title", errors, 120)
        bounded_string(value["assistant_relationship"], "#{path}.assistant_relationship", errors, 400)
        bounded_string(value["disclosure"], "#{path}.disclosure", errors, 500)
        bounded_string(value["audience"], "#{path}.audience", errors, 500)
        bounded_string(value["client_term"], "#{path}.client_term", errors, 80)
      end

      def validate_voice(value, errors)
        path = "$.voice"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[tone_traits energy accountability_style language_style], path, errors)
        enum_array(value["tone_traits"], "#{path}.tone_traits", errors, range: 1..TONE_TRAITS.length, values: TONE_TRAITS)
        errors << "#{path}.energy is not a supported voice choice" unless value["energy"].in?(ENERGY_STYLES)
        unless value["accountability_style"].in?(ACCOUNTABILITY_STYLES)
          errors << "#{path}.accountability_style is not a supported voice choice"
        end
        enum_array(
          value["language_style"],
          "#{path}.language_style",
          errors,
          range: 1..LANGUAGE_STYLES.length,
          values: LANGUAGE_STYLES
        )
      end

      def validate_coaching(value, errors)
        path = "$.coaching"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[philosophy method principles do do_not], path, errors)
        bounded_string(value["philosophy"], "#{path}.philosophy", errors, 1_200)
        bounded_string(value["method"], "#{path}.method", errors, 600)
        string_array(value["principles"], "#{path}.principles", errors, range: 1..16, item_max: 400)
        string_array(value["do"], "#{path}.do", errors, range: 0..16, item_max: 400)
        string_array(value["do_not"], "#{path}.do_not", errors, range: 0..16, item_max: 400)
      end

      def validate_culture(value, errors)
        path = "$.culture"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[locale_label context local_realities references], path, errors)
        bounded_string(value["locale_label"], "#{path}.locale_label", errors, 120)
        bounded_string(value["context"], "#{path}.context", errors, 1_000)
        string_array(value["local_realities"], "#{path}.local_realities", errors, range: 0..16, item_max: 300)
        Array(value["local_realities"]).each_with_index do |reality, index|
          next unless reality.is_a?(String) && reality.strip.present?
          next if CulturalSafetyPolicy.factual_local_reality?(reality)

          errors << "#{path}.local_realities[#{index}] must be a concrete access, cost, calendar, weather, or regulatory fact"
        end
        string_array(value["references"], "#{path}.references", errors, range: 0..16, item_max: 300)
      end

      def validate_phrases(value, errors)
        path = "$.phrases"
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain at most 24 items" unless value.length.between?(0, 24)
        artifact_ids = []
        value.each_with_index do |phrase, index|
          item_path = "#{path}[#{index}]"
          unless phrase.is_a?(Hash)
            errors << "#{item_path} must be an object"
            next
          end
          exact_keys(
            phrase,
            %w[artifact_id provenance source_user_id source_role_at_capture text meaning allowed_contexts prohibited_contexts frequency caution fingerprint],
            item_path,
            errors
          )
          artifact_ids << phrase["artifact_id"]
          errors << "#{item_path}.artifact_id must be a UUID" unless phrase["artifact_id"].to_s.match?(ARTIFACT_ID_PATTERN)
          errors << "#{item_path}.provenance is not supported" unless phrase["provenance"].in?(PHRASE_PROVENANCE)
          bounded_integer(phrase["source_user_id"], "#{item_path}.source_user_id", errors, 1..2_147_483_647)
          captured_role = phrase["source_role_at_capture"]
          errors << "#{item_path}.source_role_at_capture is not supported" unless captured_role.in?(PHRASE_SOURCE_ROLES)
          if phrase["provenance"] == "participant_supplied" && captured_role != "participant"
            errors << "#{item_path}.source_role_at_capture must be participant for participant-supplied wording"
          elsif phrase["provenance"] == "coach_authored" && !captured_role.in?(%w[admin coach])
            errors << "#{item_path}.source_role_at_capture must be coach or admin for coach-authored wording"
          end
          bounded_string(phrase["text"], "#{item_path}.text", errors, 100)
          bounded_string(phrase["meaning"], "#{item_path}.meaning", errors, 300)
          enum_array(phrase["allowed_contexts"], "#{item_path}.allowed_contexts", errors, range: 1..PHRASE_CONTEXTS.length, values: PHRASE_CONTEXTS)
          enum_array(phrase["prohibited_contexts"], "#{item_path}.prohibited_contexts", errors, range: 0..PHRASE_CONTEXTS.length, values: PHRASE_CONTEXTS)
          errors << "#{item_path}.frequency is not supported" unless phrase["frequency"].in?(FREQUENCIES)
          optional_bounded_string(phrase["caution"], "#{item_path}.caution", errors, 300)
          expected_fingerprint = artifact_fingerprint(phrase)
          unless phrase["fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
              ActiveSupport::SecurityUtils.secure_compare(phrase["fingerprint"], expected_fingerprint)
            errors << "#{item_path}.fingerprint must match the exact phrase artifact"
          end
        end
        errors << "#{path} artifact IDs must be unique" unless artifact_ids.compact.uniq.length == artifact_ids.compact.length
      end

      def validate_curriculum(value, errors)
        path = "$.curriculum"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[guidance scripts examples], path, errors)
        titled_content_array(value["guidance"], "#{path}.guidance", errors)
        scripts_array(value["scripts"], "#{path}.scripts", errors)
        examples_array(value["examples"], "#{path}.examples", errors)
      end

      def authoring_configuration(config)
        authored = config.deep_dup
        authored["phrases"] = Array(authored["phrases"]).map do |phrase|
          next phrase unless phrase.is_a?(Hash)

          phrase.except("artifact_id", "provenance", "source_user_id", "source_role_at_capture", "fingerprint")
        end
        authored
      end

      def titled_content_array(value, path, errors)
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain at most 20 items" unless value.length.between?(0, 20)
        value.each_with_index do |item, index|
          item_path = "#{path}[#{index}]"
          unless item.is_a?(Hash)
            errors << "#{item_path} must be an object"
            next
          end
          exact_keys(item, %w[title content], item_path, errors)
          bounded_string(item["title"], "#{item_path}.title", errors, 140)
          bounded_string(item["content"], "#{item_path}.content", errors, 1_200)
        end
      end

      def scripts_array(value, path, errors)
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain at most 20 items" unless value.length.between?(0, 20)
        value.each_with_index do |item, index|
          item_path = "#{path}[#{index}]"
          unless item.is_a?(Hash)
            errors << "#{item_path} must be an object"
            next
          end
          exact_keys(item, %w[title steps], item_path, errors)
          bounded_string(item["title"], "#{item_path}.title", errors, 140)
          string_array(item["steps"], "#{item_path}.steps", errors, range: 1..12, item_max: 500)
        end
      end

      def examples_array(value, path, errors)
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain at most 20 items" unless value.length.between?(0, 20)
        value.each_with_index do |item, index|
          item_path = "#{path}[#{index}]"
          unless item.is_a?(Hash)
            errors << "#{item_path} must be an object"
            next
          end
          exact_keys(item, %w[participant assistant], item_path, errors)
          bounded_string(item["participant"], "#{item_path}.participant", errors, 600)
          bounded_string(item["assistant"], "#{item_path}.assistant", errors, 1_200)
        end
      end

      def validate_response_shape(value, errors)
        path = "$.response_shape"
        return object_required(value, path, errors) unless value.is_a?(Hash)

        exact_keys(value, %w[min_sentences max_sentences max_characters plain_text_only validate_before_coaching next_move_required], path, errors)
        bounded_integer(value["min_sentences"], "#{path}.min_sentences", errors, 1..10)
        bounded_integer(value["max_sentences"], "#{path}.max_sentences", errors, 1..12)
        if value["min_sentences"].is_a?(Integer) && value["max_sentences"].is_a?(Integer) && value["min_sentences"] > value["max_sentences"]
          errors << "#{path}.max_sentences must be at least min_sentences"
        end
        bounded_integer(value["max_characters"], "#{path}.max_characters", errors, 200..4_000)
        errors << "#{path}.validate_before_coaching must be true" unless value["validate_before_coaching"] == true
        errors << "#{path}.next_move_required must be true" unless value["next_move_required"] == true
        errors << "#{path}.plain_text_only must be true or false" unless value["plain_text_only"].in?([ true, false ])
      end

      def exact_keys(value, expected, path, errors)
        return unless value.is_a?(Hash)

        actual = value.keys
        (expected - actual).each { |key| errors << "#{path}.#{key} is required" }
        (actual - expected).each { |key| errors << "#{path}.#{key} is not supported" }
      end

      def bounded_string(value, path, errors, maximum)
        errors << "#{path} must be a non-blank string up to #{maximum} characters" unless value.is_a?(String) && value.strip.present? && value.length <= maximum
      end

      def optional_bounded_string(value, path, errors, maximum)
        errors << "#{path} must be a string up to #{maximum} characters" unless value.is_a?(String) && value.length <= maximum
      end

      def string_array(value, path, errors, range:, item_max:)
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain #{range.min} to #{range.max} items" unless range.cover?(value.length)
        value.each_with_index { |item, index| bounded_string(item, "#{path}[#{index}]", errors, item_max) }
      end

      def enum_array(value, path, errors, range:, values:)
        return array_required(value, path, errors) unless value.is_a?(Array)

        errors << "#{path} must contain #{range.min} to #{range.max} items" unless range.cover?(value.length)
        value.each_with_index do |item, index|
          errors << "#{path}[#{index}] is not supported" unless item.is_a?(String) && item.in?(values)
        end
      end

      def bounded_integer(value, path, errors, range)
        errors << "#{path} must be an integer from #{range.min} to #{range.max}" unless value.is_a?(Integer) && range.cover?(value)
      end

      def object_required(value, path, errors)
        errors << "#{path} must be an object"
      end

      def array_required(value, path, errors)
        errors << "#{path} must be an array"
      end
    end
  end
end
