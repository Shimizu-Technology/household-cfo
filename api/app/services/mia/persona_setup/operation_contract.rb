# frozen_string_literal: true

require "json"

module Mia
  module PersonaSetup
    class OperationContract
      MAX_OPERATIONS = 24
      MAX_OPERATIONS_BYTES = 32_768
      MAX_STATE_BYTES = 65_536
      SET_PATHS = %w[
        description
        identity.assistant_name identity.human_coach_name identity.human_coach_title identity.assistant_relationship
        identity.disclosure identity.audience identity.client_term
        voice.tone_traits voice.energy voice.accountability_style voice.language_style
        coaching.philosophy coaching.method coaching.principles coaching.do coaching.do_not
        culture.locale_label culture.context culture.local_realities culture.references
        curriculum.guidance curriculum.scripts curriculum.examples
        response_shape.min_sentences response_shape.max_sentences response_shape.max_characters response_shape.plain_text_only
      ].freeze
      RESTRICTED_EXACT_PATHS = %w[
        identity.assistant_name identity.human_coach_name identity.human_coach_title
        culture.locale_label culture.context culture.local_realities culture.references
      ].freeze
      MIA_DRAFTABLE_PATHS = %w[coaching.philosophy].freeze
      OPERATIONS = %w[set add_phrase remove_phrase].freeze
      SOURCES = %w[coach_quote mia_drafted].freeze

      class ContractError < ArgumentError
        attr_reader :code

        def initialize(message, code: "persona_setup_invalid")
          @code = code
          super(message)
        end
      end

      def initialize(actor:, user_message:, persona:)
        @actor = actor
        @user_message = normalize_text(user_message, max: 4_000)
        @persona = persona
      end

      def build(raw_operations)
        operations = Array(raw_operations)
        raise ContractError, "Mia proposed too many changes at once." if operations.empty? || operations.length > MAX_OPERATIONS

        before_state = PersonaDraftUpdater.state_for(persona)
        after_state = before_state.deep_dup
        normalized = operations.map { |operation| normalize_operation(operation, after_state) }
        unless participant_artifacts(before_state) == participant_artifacts(after_state)
          raise ContractError, "Participant-supplied phrase artifacts cannot be changed by setup chat."
        end
        prepared = PersonaSchema.prepare_draft_artifacts(
          after_state.fetch("draft_config"),
          source_user_id: actor.id,
          source_role_at_capture: actor.role,
          existing_configuration: persona.draft_config,
          allow_coach_artifact_edits: true
        )
        after_state["draft_config"] = PersonaSchema.validate!(prepared)
        if JSON.generate(normalized).b.bytesize > MAX_OPERATIONS_BYTES ||
            JSON.generate(before_state).b.bytesize > MAX_STATE_BYTES ||
            JSON.generate(after_state).b.bytesize > MAX_STATE_BYTES
          raise ContractError, "Mia returned a setup proposal that is too large to review safely."
        end
        if PersonaDraftUpdater.state_digest(before_state) == PersonaDraftUpdater.state_digest(after_state)
          raise ContractError.new("That would not change the current persona draft.", code: "persona_setup_no_change")
        end

        { operations: normalized, before_state:, after_state: }
      rescue PersonaSchema::InvalidConfiguration => error
        raise ContractError.new(error.errors.first, code: "persona_invalid")
      end

      private

      attr_reader :actor, :user_message, :persona

      def normalize_operation(raw, after_state)
        operation = PersonaSchema.normalize(raw)
        unless operation.is_a?(Hash) && operation.keys.sort == %w[evidence_quote op path source_basis value]
          raise ContractError, "Mia returned an unsupported change shape."
        end
        op = operation.fetch("op").to_s
        path = operation.fetch("path").to_s
        source = operation.fetch("source_basis").to_s
        evidence = normalize_text(operation.fetch("evidence_quote"), max: 500, allow_blank: source == "mia_drafted")
        raise ContractError, "Mia returned an unsupported change operation." unless op.in?(OPERATIONS)
        raise ContractError, "Mia returned an unsupported evidence type." unless source.in?(SOURCES)
        validate_evidence!(op:, path:, value: operation["value"], source:, evidence:)

        normalized = { "op" => op, "path" => path, "value" => operation["value"], "source_basis" => source, "evidence_quote" => evidence }
        case op
        when "set"
          raise ContractError, "Mia tried to change a protected persona field." unless path.in?(SET_PATHS)

          set_path!(after_state, path, operation["value"])
        when "add_phrase"
          raise ContractError, "Phrase changes must use the phrases field." unless path == "phrases"

          add_phrase!(after_state, operation.fetch("value"))
        when "remove_phrase"
          raise ContractError, "Phrase changes must use the phrases field." unless path == "phrases"

          remove_phrase!(after_state, operation.fetch("value"))
        end
        normalized
      end

      def validate_evidence!(op:, path:, value:, source:, evidence:)
        if source == "coach_quote"
          unless evidence.present? && user_message.include?(evidence)
            raise ContractError, "Every coach-authored change must cite exact wording from this message."
          end
        else
          allowed = op == "set" && path.in?(MIA_DRAFTABLE_PATHS)
          requested = user_message.match?(/\b(?:draft|suggest|propose|help me write|create|come up with)\b/i) &&
            user_message.match?(/\b(?:coaching\s+)?philosoph(?:y|ies)\b/i)
          raise ContractError, "Mia can draft only a coaching philosophy after an explicit philosophy request." unless allowed && requested
        end

        if RESTRICTED_EXACT_PATHS.include?(path) || op == "add_phrase"
          raise ContractError, "Names, community facts, and phrases require exact coach wording." unless source == "coach_quote"
          exact_values = if op == "add_phrase"
            [ PersonaSchema.normalize(value).to_h["text"] ]
          else
            changed_exact_strings(path, value)
          end
          exact_values.each do |text|
            next if text.blank? || user_message.include?(text)

            raise ContractError, "Names, community facts, and phrases must appear exactly in the coach's message."
          end
        end
        return unless path.start_with?("voice.")

        voice_request = user_message.match?(/\b(?:voice|tone|style|wording|language|warm|direct|calm|formal|concise|encouraging|lighthearted|patient)\b/i)
        raise ContractError, "A location label alone cannot authorize a voice or dialect change." unless source == "coach_quote" && voice_request
      end

      def set_path!(state, path, value)
        keys = path.split(".")
        if keys.first == "description"
          state["description"] = normalize_text(value, max: 2_000, allow_blank: true)
          return
        end

        target = state.fetch("draft_config")
        keys[0...-1].each { |key| target = target.fetch(key) }
        target[keys.last] = PersonaSchema.normalize(value)
      rescue KeyError
        raise ContractError, "Mia tried to change a field that is not part of persona setup."
      end

      def add_phrase!(state, raw_value)
        value = PersonaSchema.normalize(raw_value)
        permitted = %w[text meaning allowed_contexts prohibited_contexts frequency caution]
        unless value.is_a?(Hash) && (value.keys - permitted).empty? && value.key?("text")
          raise ContractError, "Mia returned an unsupported phrase shape."
        end
        phrase = value.slice(*permitted).merge("provenance" => "coach_authored")
        state.fetch("draft_config").fetch("phrases") << phrase
      end

      def remove_phrase!(state, raw_value)
        value = PersonaSchema.normalize(raw_value)
        unless value.is_a?(String) && user_message.include?(value)
          raise ContractError, "Removing a phrase requires its exact wording in the coach's message."
        end
        phrases = state.fetch("draft_config").fetch("phrases")
        index = phrases.index { |phrase| phrase.is_a?(Hash) && phrase["text"] == value }
        raise ContractError, "The requested phrase is not in this persona." unless index

        phrases.delete_at(index)
      end

      def exact_strings(value)
        case value
        when String then [ value ]
        when Array then value.flat_map { |child| exact_strings(child) }
        when Hash then value.values.flat_map { |child| exact_strings(child) }
        else []
        end
      end

      def changed_exact_strings(path, value)
        current = path.split(".").reduce(persona.draft_config) { |target, key| target.to_h[key] }
        added = exact_strings(value) - exact_strings(current)
        return added unless value.is_a?(Array) && current.is_a?(Array)

        added | (exact_strings(current) - exact_strings(value))
      end

      def participant_artifacts(state)
        Array(state.dig("draft_config", "phrases"))
          .select { |phrase| phrase.is_a?(Hash) && phrase["provenance"] == "participant_supplied" }
      end

      def normalize_text(value, max:, allow_blank: false)
        text = value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish
        raise ContractError, "Text is missing or too long." if (!allow_blank && text.blank?) || text.length > max

        text
      end
    end
  end
end
