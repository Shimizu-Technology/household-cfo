# frozen_string_literal: true

require "json"
require "set"

module Mia
  module PersonaSetup
    class OperationContract
      MAX_OPERATIONS = 24
      MAX_OPERATIONS_BYTES = 32_768
      MAX_STATE_BYTES = 65_536
      JSONB_TEXT_MARGIN_BYTES = 1_024
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
      TRANSCRIPT_DRAFTABLE_PATHS = %w[
        voice.tone_traits voice.energy voice.accountability_style voice.language_style
        coaching.philosophy coaching.method coaching.principles coaching.do coaching.do_not
        curriculum.examples
      ].freeze
      OPERATIONS = %w[set add_phrase remove_phrase].freeze
      SOURCES = %w[coach_quote mia_drafted].freeze

      class ContractError < ArgumentError
        attr_reader :code

        def initialize(message, code: "persona_setup_invalid")
          @code = code
          super(message)
        end

        def review_note
          {
            "persona_setup_evidence_missing" => "The supporting words were missing from your message.",
            "persona_setup_exact_wording" => "It used wording you did not provide.",
            "persona_setup_text_evidence" => "Mia could not match this to your words. Say it again in your own words, or add a phrase in Teaching.",
            "persona_setup_voice_evidence" => "Please describe which voice choices you want to add or remove.",
            "persona_setup_drafting_not_requested" => "Please ask for a coaching philosophy before Mia writes one.",
            "persona_setup_crisis_phrase" => "Coaching phrases cannot be used during crisis support.",
            "persona_setup_participant_phrase" => "A participant’s own phrase must stay unchanged.",
            "persona_setup_duplicate" => "Only one change to each setting can be reviewed at a time.",
            "persona_setup_no_change" => "It already matches your assistant.",
            "persona_setup_too_large" => "It was too large to review at once.",
            "persona_invalid" => "It did not meet the rules that protect participants."
          }.fetch(code, "Mia could not prepare it for review. Try Guided setup.")
        end

        def public_message
          case code
          when "persona_setup_evidence_missing", "persona_setup_exact_wording"
            "This suggestion used wording you did not provide. Please include the exact words you want."
          when "persona_setup_text_evidence"
            "Please include the words that support this coaching or teaching suggestion."
          when "persona_setup_voice_evidence"
            "Please describe how you speak to clients, such as warm, direct, or brief. A place name alone cannot describe your voice."
          when "persona_setup_drafting_not_requested"
            "Please ask for a coaching philosophy before Mia writes one for you."
          when "persona_setup_crisis_phrase"
            "Coaching phrases cannot be used when someone needs crisis support."
          when "persona_setup_participant_phrase"
            "A participant’s own phrase must stay unchanged."
          when "persona_setup_duplicate"
            "Mia suggested two changes to the same setting. Please keep one."
          when "persona_setup_no_change"
            "These suggestions already match your assistant. Tell Mia what you would like to change."
          when "persona_setup_too_large"
            "There were too many suggestions to review at once. Save or reject the current suggestions, then describe one change at a time."
          when "persona_invalid"
            if message.include?("stereotype")
              "This suggestion could stereotype a group of people. Please describe your own coaching approach."
            elsif message.include?("dialect, slang, or cultural traits")
              "A place or identity alone cannot describe your voice. Please share your own words."
            else
              "This suggestion did not meet the rules that protect participants. Try a different description or use Guided setup."
            end
          else
            "Mia could not prepare this suggestion for review. Try a shorter description or use Guided setup."
          end
        end
      end

      def initialize(actor:, user_message:, persona:, previous_operations: [], evidence_state: nil)
        @actor = actor
        @user_message = user_message.to_s.unicode_normalize(:nfkc)
        @persona = persona
        @previous_operations = previous_operations
        @evidence_state = evidence_state || persona.draft_config
      end

      # Keep the strict contract as the authority. Each accepted prefix is fully
      # checked, and a rejected candidate never mutates the accepted snapshot.
      def build_partial(raw_operations)
        operations = Array(raw_operations)
        return build(raw_operations) if operations.empty? || operations.length > MAX_OPERATIONS

        begin
          return build(merge_previous(operations)).merge(dropped: [])
        rescue ContractError
          # A mixed proposal can still contain useful, safe changes.
        end

        accepted = []
        dropped = []
        built = nil
        first_error = nil
        pending = operations.each_with_index.to_a
        loop do
          deferred = []
          dropped = []
          pending.each do |operation, index|
            begin
              candidate = build(merge_previous(accepted + [ operation ]))
              accepted << operation
              built = candidate
            rescue ContractError => error
              first_error ||= error
              deferred << [ operation, index ]
              dropped << { index: index, label: suggestion_label(operation), code: error.code, message: error.review_note }
            end
          end
          # A later valid field can make an earlier one valid (for example,
          # raising both sentence limits). Retry only while progress is made.
          break if deferred.empty? || deferred.length == pending.length

          pending = deferred
        end
        raise first_error unless built

        built.merge(dropped: dropped)
      end

      def build(raw_operations)
        operations = Array(raw_operations)
        raise ContractError.new("Mia proposed too many changes at once.", code: "persona_setup_too_large") if operations.empty? || operations.length > MAX_OPERATIONS

        before_state = PersonaDraftUpdater.state_for(persona)
        after_state = before_state.deep_dup
        mutation_targets = Set.new
        normalized = operations.map do |operation|
          normalize_operation(operation, after_state) do |normalized_operation|
            target = mutation_target(normalized_operation)
            raise ContractError.new("Mia proposed more than one change to the same field.", code: "persona_setup_duplicate") unless mutation_targets.add?(target)
          end
        end
        reconcile_prohibitions!(after_state)
        unless participant_artifacts(before_state) == participant_artifacts(after_state)
          raise ContractError.new("Participant-supplied phrase artifacts cannot be changed by setup chat.", code: "persona_setup_participant_phrase")
        end
        prepared = PersonaSchema.prepare_draft_artifacts(
          after_state.fetch("draft_config"),
          source_user_id: actor.id,
          source_role_at_capture: actor.role,
          existing_configuration: persona.draft_config,
          allow_coach_artifact_edits: true
        )
        after_state["draft_config"] = PersonaSchema.validate!(prepared)
        if postgres_jsonb_text_upper_bound(normalized) > MAX_OPERATIONS_BYTES ||
            postgres_jsonb_text_upper_bound(before_state) > MAX_STATE_BYTES ||
            postgres_jsonb_text_upper_bound(after_state) > MAX_STATE_BYTES
          raise ContractError.new("Mia returned a setup proposal that is too large to review safely.", code: "persona_setup_too_large")
        end
        if @previous_operations.empty? && PersonaDraftUpdater.state_digest(before_state) == PersonaDraftUpdater.state_digest(after_state)
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
        value = op == "add_phrase" ? normalize_phrase_value(operation["value"]) : operation["value"]
        value = preserve_pending_list(path, value) if op == "set"
        validate_evidence!(op:, path:, value:, source:, evidence:) unless @previous_operations.include?(operation)

        normalized = { "op" => op, "path" => path, "value" => value, "source_basis" => source, "evidence_quote" => evidence }
        yield normalized
        case op
        when "set"
          raise ContractError, "Mia tried to change a protected persona field." unless path.in?(SET_PATHS)

          set_path!(after_state, path, value)
        when "add_phrase"
          raise ContractError, "Phrase changes must use the phrases field." unless path == "phrases"

          add_phrase!(after_state, value)
        when "remove_phrase"
          raise ContractError, "Phrase changes must use the phrases field." unless path == "phrases"

          remove_phrase!(after_state, operation.fetch("value"))
        end
        normalized
      end

      def validate_evidence!(op:, path:, value:, source:, evidence:)
        if source == "coach_quote"
          unless evidence.present? && user_message.squish.include?(evidence)
            raise ContractError.new("Every coach-authored change must cite exact wording from this message.", code: "persona_setup_evidence_missing")
          end
        else
          if transcript_request? && op == "set" && path.in?(TRANSCRIPT_DRAFTABLE_PATHS)
            unless evidence.present? && user_message.squish.include?(evidence)
              raise ContractError.new("A transcript suggestion must cite exact source wording.", code: "persona_setup_evidence_missing")
            end

          else
            allowed = op == "set" && path.in?(MIA_DRAFTABLE_PATHS)
            requested = user_message.match?(/\b(?:draft|suggest|propose|help me write|create|come up with)\b/i) &&
              user_message.match?(/\b(?:coaching\s+)?philosoph(?:y|ies)\b/i)
            raise ContractError.new("Mia can draft only a coaching philosophy after an explicit philosophy request.", code: "persona_setup_drafting_not_requested") unless allowed && requested
          end
        end

        if RESTRICTED_EXACT_PATHS.include?(path) || op == "add_phrase"
          raise ContractError.new("Names, community facts, and phrases require exact coach wording.", code: "persona_setup_exact_wording") unless source == "coach_quote"
          exact_values = if op == "add_phrase"
            [ PersonaSchema.normalize(value).to_h["text"] ]
          else
            changed_exact_strings(path, value)
          end
          if op == "add_phrase" && !PhraseSuggestions.new(message: user_message, coach_name: persona.draft_config.dig("identity", "human_coach_name")).exact_quote(value["text"])
            raise ContractError.new("Phrases require the coach's own words and permission to use them.", code: "persona_setup_exact_wording")
          end
          exact_values.each do |text|
            next if text.blank? || user_message.include?(text)

            raise ContractError.new("Names, community facts, and phrases must appear exactly in the coach's message.", code: "persona_setup_exact_wording")
          end
        end
        if path.start_with?("coaching.", "curriculum.") || op == "add_phrase"
          # Explicitly requested creative philosophy is labelled Mia drafted.
          unless source == "mia_drafted" && !transcript_request?
            values = if op == "add_phrase"
              [ value.fetch("meaning") ]
            elsif path.start_with?("curriculum.")
              current = path.split(".").reduce(@evidence_state) { |target, key| target.to_h[key] }
              added = Array(value) - Array(current)
              added.flat_map { |item| item.is_a?(Hash) ? item.values : item }
            else
              current = path.split(".").reduce(@evidence_state) { |target, key| target.to_h[key] }
              exact_strings(value) - exact_strings(current)
            end
            unless exact_strings(values).all? { |item| TextEvidence.supports?(evidence, item) }
              raise ContractError.new("The suggestion must be supported by its cited words.", code: "persona_setup_text_evidence")
            end
          end
        end
        return unless path.start_with?("voice.")

        current = path.split(".").reduce(@evidence_state) { |target, key| target.to_h[key] }
        added = exact_strings(value) - exact_strings(current)
        removed = value.is_a?(Array) && current.is_a?(Array) ? exact_strings(current) - exact_strings(value) : []
        return if added.empty? && removed.empty?

        supported = (source == "coach_quote" || transcript_request?) &&
          CulturalSafetyPolicy.violations(evidence, field: :style_instruction).empty? &&
          added.all? { |item| VoiceEvidence.supports?(evidence, item) } &&
          removed.all? { |item| VoiceEvidence.supports?(evidence, item, removal: true) }
        unless supported
          raise ContractError.new("Each added voice choice needs supporting words; removing one needs an explicit request.", code: "persona_setup_voice_evidence")
        end
      end

      # Only the server passes already sealed, pending operations here. New
      # claims still use this turn's evidence and replace only the same target.
      def preserve_pending_list(path, value)
        previous = @previous_operations.find { |operation| operation["op"] == "set" && operation["path"] == path }
        return value unless previous || path.in?(%w[coaching.do coaching.do_not])

        current = previous ? previous["value"] : path.split(".").reduce(@evidence_state) { |target, key| target.to_h[key] }
        return value unless value.is_a?(Array) && current.is_a?(Array)
        return value if path.start_with?("voice.") # Voice removals have their own evidence check.

        kept = current.reject { |item| removal_requested?(item) }
        # Ignore an unsupported omission, including "do not remove".
        (kept + value).uniq
      end

      def removal_requested?(item)
        return false unless item.is_a?(String)

        user_message.split(/[.!?;\n]/).any? do |clause|
          next false if clause.match?(/\b(?:do not|don['’ʼ]?t|never|without)\s+(?:ever\s+)?(?:remove|drop|take out|delete|replace)\b/i)
          next false unless clause.match?(/\b(?:remove|drop|take out|delete|replace)\b/i)

          reference = clause.downcase.gsub(/\b(?:actually|remove|drop|take out|delete|replace|the|one|about|please)\b/, " ").scan(/[[:alnum:]]+/)
          words = item.downcase.scan(/[[:alnum:]]+/)
          reference.any? && (reference - words).empty?
        end
      end

      def merge_previous(operations)
        targets = operations.filter_map do |operation|
          next unless operation.is_a?(Hash) && operation.key?("op") && operation.key?("path") && operation.key?("value")

          mutation_target(PersonaSchema.normalize(operation))
        end
        previous = @previous_operations.reject { |operation| targets.include?(mutation_target(operation)) }
        previous + operations
      end

      def suggestion_label(operation)
        value = operation.is_a?(Hash) ? operation["value"] : nil
        # Bound the excerpt so all 24 rejected operations fit the reply limit.
        preview = if value.is_a?(Hash) && value["text"].is_a?(String)
          value["text"]
        else
          exact_strings(value).join("; ").squish
        end
        if preview.present?
          return preview if preview.length <= 48

          words = preview.split
          kept = []
          words.each do |word|
            break if (kept + [ word ]).join(" ").length > 44

            kept << word
          end
          excerpt = kept.join(" ")
          return excerpt.present? ? "#{excerpt}…" : "A long suggestion"
        end

        path = operation.is_a?(Hash) ? operation["path"] : nil
        {
          "response_shape.min_sentences" => "Shortest answer: #{value} sentences",
          "response_shape.max_sentences" => "Longest answer: #{value} sentences",
          "response_shape.max_characters" => "Longest answer: #{value} characters",
          "response_shape.plain_text_only" => "Plain text answers: #{value ? 'yes' : 'no'}"
        }.fetch(path, "One suggestion").truncate(48)
      end

      def transcript_request?
        user_message.match?(/\b(?:propose|suggest|derive)\b/i) && user_message.match?(/\btranscripts?\b/i)
      end

      def mutation_target(operation)
        return "set:#{operation.fetch('path')}" if operation.fetch("op") == "set"

        value = PersonaSchema.normalize(operation.fetch("value"))
        phrase = value.is_a?(Hash) ? value.fetch("text").to_s : value.to_s
        "phrase:#{PhraseSuggestions.key(phrase)}"
      end

      def reconcile_prohibitions!(state)
        coaching = state.fetch("draft_config").fetch("coaching")
        prohibitions = Array(coaching["do_not"])
        coaching["do"] = Array(coaching["do"]).reject do |item|
          prohibitions.any? do |ban|
            positive = ban.gsub(/\b(?:do not|don['’ʼ]?t|never|avoid|stop)\b/i, "")
            TextEvidence.supports?(positive, item)
          end
        end
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
        value = normalize_phrase_value(raw_value)
        permitted = %w[text meaning allowed_contexts prohibited_contexts frequency caution]
        phrase = value.slice(*permitted).merge("provenance" => "coach_authored")
        phrases = state.fetch("draft_config").fetch("phrases")
        return if phrases.any? { |item| PhraseSuggestions.key(item["text"]) == PhraseSuggestions.key(phrase["text"]) }

        phrases << phrase
      end

      def normalize_phrase_value(raw_value)
        value = PersonaSchema.normalize(raw_value)
        required = %w[text meaning allowed_contexts prohibited_contexts frequency caution]
        string_keys = %w[text meaning frequency caution]
        array_keys = %w[allowed_contexts prohibited_contexts]
        valid = value.is_a?(Hash) && value.keys.sort == required.sort &&
          string_keys.all? { |key| value[key].is_a?(String) } &&
          array_keys.all? { |key| value[key].is_a?(Array) && value[key].all? { |item| item.is_a?(String) } }
        raise ContractError, "Mia returned an unsupported phrase shape." unless valid
        if value.fetch("allowed_contexts").include?("crisis")
          raise ContractError.new("Coaching phrases cannot be used during a crisis.", code: "persona_setup_crisis_phrase")
        end
        # This locked safety boundary is part of every reviewable suggestion,
        # even when the transcript never mentions crisis handling.
        value.merge("prohibited_contexts" => (value.fetch("prohibited_contexts") + [ "crisis" ]).uniq)
      end

      def remove_phrase!(state, raw_value)
        value = PersonaSchema.normalize(raw_value)
        unless value.is_a?(String) && user_message.include?(value)
          raise ContractError, "Removing a phrase requires its exact wording in the coach's message."
        end
        phrases = state.fetch("draft_config").fetch("phrases")
        index = phrases.index { |phrase| phrase.is_a?(Hash) && phrase["text"] == value }
        unless index
          pending_add = @previous_operations.any? { |op| op["op"] == "add_phrase" && PhraseSuggestions.key(op.dig("value", "text")) == PhraseSuggestions.key(value) }
          return if pending_add

          raise ContractError, "The requested phrase is not in this persona."
        end

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
        current = path.split(".").reduce(@evidence_state) { |target, key| target.to_h[key] }
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

      def postgres_jsonb_text_upper_bound(value)
        compact = JSON.generate(value).b
        compact.bytesize + compact.count(",:") + JSONB_TEXT_MARGIN_BYTES
      end
    end
  end
end
