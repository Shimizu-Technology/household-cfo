# frozen_string_literal: true

module Mia
  module PersonaSetup
    class ProposalApplier
      class Error < StandardError
        attr_reader :code, :status

        def initialize(message, code:, status: :conflict)
          @code = code
          @status = status
          super(message)
        end
      end

      def initialize(proposal:, actor:, workspace:)
        @proposal_id = proposal.id
        @session_id = proposal.coach_persona_setup_session_id
        @persona_id = proposal.session.coach_persona_id
        @actor_id = actor.id
        @workspace_id = workspace.id
      end

      def apply!(idempotency_key:, accepted_operation_indexes: nil, accepted_list_item_indexes: nil)
        key = normalize_key(idempotency_key)
        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          proposal = session.proposals.lock.find(proposal_id)
          indexes = selected_indexes(proposal, accepted_operation_indexes)
          list_indexes = selected_list_indexes(proposal, indexes, accepted_list_item_indexes)
          if proposal.status == "applied"
            if secure_match?(proposal.resolution_idempotency_key, key) &&
                (proposal.accepted_operation_indexes || proposal.operations.each_index.to_a) == indexes &&
                (proposal.accepted_list_item_indexes || {}) == list_indexes
              return authorization.persona
            end

            raise Error.new("This proposal was already applied with a different request.", code: "persona_setup_resolution_conflict")
          end
          ensure_pending!(proposal, session)
          verify_seal!(proposal, authorization.persona)

          state = selected_state(proposal, indexes, list_indexes)
          updater = PersonaDraftUpdater.new(
            persona: authorization.persona,
            actor: authorization.actor,
            workspace: authorization.workspace,
            origin_proposal_id: proposal.id
          )
          updater.apply_locked!(
            expected_draft_revision: proposal.base_draft_revision,
            description: state.fetch("description"),
            draft_config: state.fetch("draft_config"),
            prepared: true,
            expected_state_digest: PersonaDraftUpdater.state_digest(state)
          )
          persona = authorization.persona.reload
          proposal.update!(accepted_operation_indexes: indexes, accepted_list_item_indexes: list_indexes)
          proposal.resolve!(status: "applied", actor: authorization.actor, idempotency_key: key)
          session.update!(
            base_draft_revision: persona.draft_revision,
            base_config_digest: PersonaSchema.digest(persona.draft_config),
            last_activity_at: Time.current
          )
          persona
        end
      rescue PersonaDraftUpdater::Error => error
        status = if error.code == "persona_not_found"
          :not_found
        elsif error.code.in?(%w[persona_invalid persona_setup_no_change])
          :unprocessable_entity
        else
          :conflict
        end
        raise Error.new(error.message, code: error.code, status:)
      rescue ActiveRecord::RecordNotUnique
        raise Error.new("That retry key was already used to resolve another proposal.", code: "persona_setup_resolution_conflict")
      end

      def reject!(idempotency_key:)
        key = normalize_key(idempotency_key)
        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          proposal = session.proposals.lock.find(proposal_id)
          if proposal.status == "rejected"
            return proposal if secure_match?(proposal.resolution_idempotency_key, key)

            raise Error.new("This proposal was already resolved with a different request.", code: "persona_setup_resolution_conflict")
          end
          ensure_pending!(proposal, session)
          proposal.resolve!(status: "rejected", actor: authorization.actor, idempotency_key: key)
          session.update!(last_activity_at: Time.current)
          proposal
        end
      rescue ActiveRecord::RecordNotUnique
        raise Error.new("That retry key was already used to resolve another proposal.", code: "persona_setup_resolution_conflict")
      end

      private

      attr_reader :proposal_id, :session_id, :persona_id, :actor_id, :workspace_id

      # The whole proposal has already passed its contract and seal checks. Copy
      # selected values from that sealed result instead of capturing artifacts a
      # second time with new identities or the actor's current role.
      def selected_state(proposal, indexes, list_indexes)
        return proposal.after_state if indexes == proposal.operations.each_index.to_a && list_indexes.empty?

        state = proposal.before_state.deep_dup
        before_phrases = proposal.before_state.fetch("draft_config").fetch("phrases")
        after_phrases = proposal.after_state.fetch("draft_config").fetch("phrases")
        added = after_phrases.reject { |phrase| before_phrases.any? { |item| item.fetch("artifact_id") == phrase.fetch("artifact_id") } }
        removed = before_phrases.reject { |phrase| after_phrases.any? { |item| item.fetch("artifact_id") == phrase.fetch("artifact_id") } }
        indexes.each do |index|
          operation = proposal.operations.fetch(index)
          case operation.fetch("op")
          when "set"
            keys = operation.fetch("path") == "description" ? [ "description" ] : [ "draft_config", *operation.fetch("path").split(".") ]
            target = keys[0...-1].reduce(state) { |value, key| value.fetch(key) }
            value = proposal.after_state.dig(*keys).deep_dup
            choices = list_indexes[index.to_s]
            value = value.each_with_index.filter_map { |item, item_index| item if choices.include?(item_index) } if choices
            target[keys.last] = value
          when "add_phrase"
            text = operation.fetch("value").fetch("text")
            phrase = added.find { |item| item.fetch("text") == text }
            state.fetch("draft_config").fetch("phrases") << phrase.deep_dup if phrase
          when "remove_phrase"
            phrase = removed.find { |item| item.fetch("text") == operation.fetch("value") }
            state.fetch("draft_config").fetch("phrases").reject! { |item| item.fetch("artifact_id") == phrase.fetch("artifact_id") } if phrase
          end
        end
        TextEvidence.reconcile_prohibitions!(state)
        state
      end

      def selected_list_indexes(proposal, indexes, values)
        return {} if values.nil?
        values = values.to_unsafe_h if values.respond_to?(:to_unsafe_h)
        unless values.is_a?(Hash) && values.all? do |key, choices|
            index = Integer(key, exception: false)
            operation = index && index >= 0 && proposal.operations[index]
            value = operation && operation["op"] == "set" && proposal.after_state.dig("draft_config", *operation["path"].split("."))
            indexes.include?(index) && operation["op"] == "set" && value.is_a?(Array) &&
              choices.is_a?(Array) && choices.all? { |choice| choice.is_a?(Integer) && choice >= 0 && choice < value.length } && choices.uniq == choices
          end
          raise Error.new("Choose valid list items to save.", code: "persona_setup_invalid", status: :unprocessable_entity)
        end
        values.transform_keys(&:to_s).transform_values(&:sort)
      end

      def authorize!
        Authorization.lock_editor!(actor_id:, workspace_id:, persona_id:) ||
          raise(Error.new("Persona setup proposal not found.", code: "persona_setup_not_found", status: :not_found))
      end

      def locked_session!
        CoachPersonaSetupSession.lock.find_by!(
          id: session_id,
          coach_persona_id: persona_id,
          coach_workspace_id: workspace_id,
          created_by_user_id: actor_id
        )
      rescue ActiveRecord::RecordNotFound
        raise Error.new("Persona setup proposal not found.", code: "persona_setup_not_found", status: :not_found)
      end

      def ensure_pending!(proposal, session)
        unless session.status == "active" && proposal.status == "pending"
          raise Error.new("This setup proposal is no longer pending.", code: "persona_setup_stale")
        end
      end

      def verify_seal!(proposal, persona)
        unless proposal.prompt_version == ProposalBuilder::PROMPT_VERSION && proposal.schema_version == ProposalBuilder::SCHEMA_VERSION
          raise Error.new("Please send that again so Mia can prepare fresh suggestions. Nothing changed.", code: "persona_setup_stale")
        end
        current_state = PersonaDraftUpdater.state_for(persona)
        expected_digest = ProposalBuilder.digest_for(
          persona:,
          base_draft_revision: proposal.base_draft_revision,
          base_config_digest: proposal.base_config_digest,
          operations: proposal.operations,
          before_state: proposal.before_state,
          after_state: proposal.after_state
        )
        valid = proposal.base_draft_revision == persona.draft_revision &&
          secure_match?(proposal.base_config_digest, PersonaSchema.digest(persona.draft_config)) &&
          secure_match?(proposal.proposal_digest, expected_digest) &&
          secure_match?(PersonaDraftUpdater.state_digest(proposal.before_state), PersonaDraftUpdater.state_digest(current_state))
        raise Error.new("The persona changed or this proposal failed verification.", code: "persona_setup_stale") unless valid
      end

      def selected_indexes(proposal, values)
        return proposal.operations.each_index.to_a if values.nil?
        unless values.is_a?(Array) && values.present? && values.all? { |index| index.is_a?(Integer) && index >= 0 && index < proposal.operations.length } && values.uniq.length == values.length
          raise Error.new("Choose at least one valid suggestion to save.", code: "persona_setup_invalid", status: :unprocessable_entity)
        end
        values.sort
      end

      def normalize_key(value)
        key = value.to_s.strip
        unless key.length.between?(8, 200) && key.match?(/\A[A-Za-z0-9._:-]+\z/)
          raise Error.new("Refresh and try again.", code: "persona_setup_idempotency_invalid", status: :unprocessable_entity)
        end
        key
      end

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
