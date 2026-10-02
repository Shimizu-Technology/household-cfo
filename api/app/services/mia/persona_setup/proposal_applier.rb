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

      def apply!(idempotency_key:)
        key = normalize_key(idempotency_key)
        ApplicationRecord.transaction do
          authorization = authorize!
          session = locked_session!
          proposal = session.proposals.lock.find(proposal_id)
          if proposal.status == "applied"
            return authorization.persona if secure_match?(proposal.resolution_idempotency_key, key)

            raise Error.new("This proposal was already applied with a different request.", code: "persona_setup_resolution_conflict")
          end
          ensure_pending!(proposal, session)
          verify_seal!(proposal, authorization.persona)

          state = proposal.after_state
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
