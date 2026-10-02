# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaSetup
    class ProposalBuilder
      PROMPT_VERSION = "coach_persona_setup_v1"
      SCHEMA_VERSION = "coach_persona_setup_operations_v1"

      def self.digest_for(persona:, base_draft_revision:, base_config_digest:, operations:, before_state:, after_state:)
        payload = {
          "persona_id" => persona.id,
          "coach_workspace_id" => persona.coach_workspace_id,
          "base_draft_revision" => base_draft_revision,
          "base_config_digest" => base_config_digest,
          "operations" => operations,
          "before_state" => before_state,
          "after_state" => after_state,
          "prompt_version" => PROMPT_VERSION,
          "schema_version" => SCHEMA_VERSION,
          "safety_policy_version" => PersonaSafetyPolicy::VERSION
        }
        Digest::SHA256.hexdigest(JSON.generate(PersonaDraftUpdater.canonicalize(payload)).b)
      end

      def initialize(persona:, actor:, user_message:)
        @persona = persona
        @actor = actor
        @user_message = user_message
      end

      def call(raw_operations)
        built = OperationContract.new(actor:, user_message:, persona:).build(raw_operations)
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
