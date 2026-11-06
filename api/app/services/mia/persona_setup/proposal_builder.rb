# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaSetup
    class ProposalBuilder
      PROMPT_VERSION = "coach_persona_setup_v6"
      SCHEMA_VERSION = "coach_persona_setup_operations_v1"

      def self.digest_for(persona:, base_draft_revision:, base_config_digest:, operations:, before_state:, after_state:, prompt_version: PROMPT_VERSION)
        payload = {
          "persona_id" => persona.id,
          "coach_workspace_id" => persona.coach_workspace_id,
          "base_draft_revision" => base_draft_revision,
          "base_config_digest" => base_config_digest,
          "operations" => operations,
          "before_state" => before_state,
          "after_state" => after_state,
          "prompt_version" => prompt_version,
          "schema_version" => SCHEMA_VERSION,
          "safety_policy_version" => PersonaSafetyPolicy::VERSION
        }
        Digest::SHA256.hexdigest(JSON.generate(PersonaDraftUpdater.canonicalize(payload)).b)
      end

      def initialize(persona:, actor:, user_message:, previous: nil)
        @persona = persona
        @actor = actor
        @user_message = user_message
        @previous = previous
      end

      def call(raw_operations, partial: false)
        previous_operations = []
        if @previous
          expected = self.class.digest_for(persona:, base_draft_revision: @previous.base_draft_revision,
            base_config_digest: @previous.base_config_digest, operations: @previous.operations,
            before_state: @previous.before_state, after_state: @previous.after_state, prompt_version: @previous.prompt_version)
          unless @previous.status == "pending" && @previous.prompt_version == PROMPT_VERSION &&
              @previous.schema_version == SCHEMA_VERSION && @previous.base_draft_revision == persona.draft_revision &&
              @previous.base_config_digest == PersonaSchema.digest(persona.draft_config) &&
              @previous.proposal_digest == expected &&
              @previous.before_state == PersonaDraftUpdater.state_for(persona)
            raise OperationContract::ContractError.new("The pending proposal uses an older review contract.", code: "persona_setup_stale_proposal")
          end
          previous_operations = @previous.operations
        end
        contract = OperationContract.new(actor:, user_message:, persona:, previous_operations:,
          evidence_state: @previous&.after_state&.fetch("draft_config"))
        built = partial ? contract.build_partial(raw_operations) : contract.build(raw_operations)
        base_digest = PersonaSchema.digest(persona.draft_config)
        digest = self.class.digest_for(
          persona:,
          base_draft_revision: persona.draft_revision,
          base_config_digest: base_digest,
          operations: built.fetch(:operations),
          before_state: built.fetch(:before_state),
          after_state: built.fetch(:after_state)
        )
        built.merge(
          base_draft_revision: persona.draft_revision,
          base_config_digest: base_digest,
          proposal_digest: digest,
          prompt_version: PROMPT_VERSION,
          schema_version: SCHEMA_VERSION
        )
      end

      private

      attr_reader :persona, :actor, :user_message
    end
  end
end
