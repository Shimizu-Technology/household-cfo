# frozen_string_literal: true

module Mia
  module PersonaSetup
    class TurnRunner
      Result = Data.define(:session, :turn, :proposal, :replayed)

      class Error < StandardError
        attr_reader :code, :status, :result

        def initialize(message, code:, status:, result: nil)
          @code = code
          @status = status
          @result = result
          super(message)
        end
      end

      def initialize(session:, actor:, workspace:, resolver: ProposalResolver.new)
        @session_id = session.id
        @persona_id = session.coach_persona_id
        @actor_id = actor.id
        @workspace_id = workspace.id
        @resolver = resolver
      end

      def call(user_message:, idempotency_key:)
        message = normalize_message(user_message)
        key = normalize_key(idempotency_key)
        reserved = reserve_turn!(message:, key:)
        return reserved if reserved.replayed

        turn = reserved.turn
        context = ContextBuilder.new(session: reserved.session, persona: reserved.session.coach_persona).call
        provider_result = resolver.call(context:, user_message: message)
        finalize_turn!(turn_id: turn.id, provider_result:)
      rescue ProposalResolver::Error => error
        failed_result = fail_turn!(turn&.id, error.code)
        raise Error.new(error.message, code: error.code, status: :service_unavailable, result: failed_result)
      rescue OperationContract::ContractError => error
        failed_result = fail_turn!(turn&.id, error.code)
        raise Error.new(error.message, code: error.code, status: :unprocessable_entity, result: failed_result)
      rescue Error
        stale_reserved_turn!(turn&.id)
        raise
      end

      private

      attr_reader :session_id, :persona_id, :actor_id, :workspace_id, :resolver

      def reserve_turn!(message:, key:)
        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          validate_session!(session, authorization.persona)
          existing = session.turns.find_by(idempotency_key: key)
          if existing
            unless secure_match?(existing.user_message, message)
              raise Error.new("That retry key belongs to a different message.", code: "persona_setup_idempotency_conflict", status: :conflict)
            end
            return Result.new(session:, turn: existing, proposal: existing.proposal, replayed: true)
          end
          if session.turns.where(status: "processing").exists?
            raise Error.new("Mia is already preparing a setup response.", code: "persona_setup_busy", status: :conflict)
          end

          position = session.turns.maximum(:position).to_i + 1
          turn = session.turns.create!(position:, idempotency_key: key, status: "processing", user_message: message)
          session.update!(last_activity_at: Time.current)
          Result.new(session:, turn:, proposal: nil, replayed: false)
        end
      rescue ActiveRecord::RecordNotUnique
        retry_result = CoachPersonaSetupTurn.find_by(coach_persona_setup_session_id: session_id, idempotency_key: key)
        unless retry_result
          raise Error.new("Mia is already preparing a setup response.", code: "persona_setup_busy", status: :conflict)
        end
        unless secure_match?(retry_result.user_message, message)
          raise Error.new("That retry key belongs to a different message.", code: "persona_setup_idempotency_conflict", status: :conflict)
        end

        Result.new(session: retry_result.session, turn: retry_result, proposal: retry_result.proposal, replayed: true)
      end

      def finalize_turn!(turn_id:, provider_result:)
        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          turn = session.turns.lock.find(turn_id)
          unless turn.status == "processing"
            return Result.new(session:, turn:, proposal: turn.proposal, replayed: true)
          end
          unless session_current?(session, authorization.persona)
            turn.update!(status: "stale", assistant_message: "The persona changed while Mia was preparing this proposal. Rebase the setup chat and try again.")
            return Result.new(session:, turn:, proposal: nil, replayed: false)
          end

          built = ProposalBuilder.new(
            persona: authorization.persona,
            actor: authorization.actor,
            user_message: turn.user_message
          ).call(provider_result.operations)
          session.proposals.where(status: "pending").order(:id).lock.each do |proposal|
            proposal.resolve!(status: "superseded", actor: authorization.actor)
          end
          proposal = CoachPersonaSetupProposal.create!(
            session:,
            turn:,
            status: "pending",
            base_draft_revision: built.fetch(:base_draft_revision),
            base_config_digest: built.fetch(:base_config_digest),
            operations: built.fetch(:operations),
            before_state: built.fetch(:before_state),
            after_state: built.fetch(:after_state),
            proposal_digest: built.fetch(:proposal_digest),
            prompt_version: built.fetch(:prompt_version),
            schema_version: built.fetch(:schema_version)
          )
          metadata = provider_result.metadata
          turn.update!(
            status: "ready",
            assistant_message: provider_result.assistant_message,
            provider: metadata["provider"],
            model: metadata["model"],
            prompt_version: metadata["prompt_version"],
            schema_version: metadata["schema_version"],
            usage: metadata["usage"] || {}
          )
          session.update!(last_activity_at: Time.current)
          Result.new(session:, turn:, proposal:, replayed: false)
        end
      end

      def fail_turn!(turn_id, code)
        return unless turn_id

        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          turn = session.turns.lock.find_by(id: turn_id)
          return unless turn
          if turn.status == "processing" && session_current?(session, authorization.persona)
            turn.update!(
              status: "failed",
              error_code: code.to_s.first(80),
              assistant_message: "I couldn't prepare a safe proposal from that message. Nothing changed. Try again or use the guided form."
            )
          elsif turn.status == "processing"
            turn.update!(status: "stale", assistant_message: "This response is stale because the persona changed.")
          end
          Result.new(session:, turn:, proposal: turn.proposal, replayed: false)
        end
      rescue ActiveRecord::RecordNotFound
        nil
      rescue Error
        stale_reserved_turn!(turn_id)
        raise
      end

      def authorize!
        Authorization.lock_editor!(actor_id:, workspace_id:, persona_id:) ||
          raise(Error.new("Persona setup session not found.", code: "persona_setup_not_found", status: :not_found))
      end

      def locked_session!
        CoachPersonaSetupSession.lock.find_by!(
          id: session_id,
          coach_persona_id: persona_id,
          coach_workspace_id: workspace_id,
          created_by_user_id: actor_id
        )
      rescue ActiveRecord::RecordNotFound
        raise Error.new("Persona setup session not found.", code: "persona_setup_not_found", status: :not_found)
      end

      def validate_session!(session, persona)
        unless session.status == "active"
          raise Error.new("This setup chat is no longer active.", code: "persona_setup_inactive", status: :conflict)
        end
        unless session_current?(session, persona)
          raise Error.new("The persona changed. Rebase this setup chat before continuing.", code: "persona_setup_stale", status: :conflict)
        end
      end

      def session_current?(session, persona)
        !persona.archived? && session.status == "active" && session.base_draft_revision == persona.draft_revision &&
          secure_match?(session.base_config_digest, PersonaSchema.digest(persona.draft_config))
      end

      def stale_reserved_turn!(turn_id)
        return unless turn_id

        ApplicationRecord.transaction do
          session = CoachPersonaSetupSession.lock.find_by(
            id: session_id,
            coach_persona_id: persona_id,
            coach_workspace_id: workspace_id,
            created_by_user_id: actor_id
          )
          turn = session&.turns&.lock&.find_by(id: turn_id)
          if turn&.status == "processing"
            turn.update!(status: "stale", assistant_message: "This response was stopped because access or the persona changed.")
          end
        end
      end

      def normalize_message(value)
        text = value.to_s.unicode_normalize(:nfkc).gsub("\r\n", "\n").gsub("\r", "\n")
          .gsub(/[[:cntrl:]]/) { |character| character.in?([ "\n", "\t" ]) ? character : " " }
          .strip
        raise Error.new("Enter a setup message between 1 and 4,000 characters.", code: "persona_setup_invalid", status: :unprocessable_entity) unless text.length.between?(1, 4_000)

        text
      end

      def normalize_key(value)
        key = value.to_s.strip
        unless key.length.between?(8, 200) && key.match?(/\A[A-Za-z0-9._:-]+\z/)
          raise Error.new("Refresh the setup chat and try again.", code: "persona_setup_idempotency_invalid", status: :unprocessable_entity)
        end

        key
      end

      def secure_match?(left, right)
        left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
      end
    end
  end
end
