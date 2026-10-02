# frozen_string_literal: true

module Mia
  module PersonaSetup
    class Serializer
      MAX_SERIALIZED_TURNS = 100
      GROUPS = {
        "identity" => "Identity",
        "voice" => "Voice",
        "coaching" => "Coaching",
        "culture" => "Community",
        "phrases" => "Phrases",
        "curriculum" => "Teaching",
        "response_shape" => "Response",
        "description" => "Identity"
      }.freeze

      def initialize(session)
        @session = session
      end

      def call
        pending = session.proposals.find_by(status: "pending")
        recent_turns = session.turns.reorder(position: :desc).limit(MAX_SERIALIZED_TURNS + 1).to_a
        {
          id: session.id,
          persona_id: session.coach_persona_id,
          workspace_id: session.coach_workspace_id,
          status: session.status,
          base_draft_revision: session.base_draft_revision,
          base_config_digest: session.base_config_digest,
          last_activity_at: session.last_activity_at,
          stale: stale?,
          turns_truncated: recent_turns.length > MAX_SERIALIZED_TURNS,
          turns: recent_turns.first(MAX_SERIALIZED_TURNS).reverse.map { |turn| serialize_turn(turn) },
          proposal: pending && serialize_proposal(pending)
        }
      end

      def serialize_proposal(proposal)
        {
          id: proposal.id,
          status: proposal.status,
          base_draft_revision: proposal.base_draft_revision,
          base_config_digest: proposal.base_config_digest,
          proposal_digest: proposal.proposal_digest,
          operations: proposal.operations,
          before_state: proposal.before_state,
          after_state: proposal.after_state,
          grouped_changes: grouped_changes(proposal),
          created_at: proposal.created_at,
          resolved_at: proposal.resolved_at
        }
      end

      private

      attr_reader :session

      def stale?
        persona = session.coach_persona
        session.status != "active" || session.base_draft_revision != persona.draft_revision ||
          session.base_config_digest != PersonaSchema.digest(persona.draft_config)
      end

      def serialize_turn(turn)
        {
          id: turn.id,
          position: turn.position,
          status: turn.status,
          user_message: turn.user_message,
          assistant_message: turn.assistant_message,
          error_code: turn.error_code,
          created_at: turn.created_at
        }
      end

      def grouped_changes(proposal)
        proposal.operations.map do |operation|
          path = operation.fetch("path")
          {
            group: GROUPS.fetch(path.split(".").first, "Other"),
            path:,
            label: path == "phrases" ? phrase_label(operation) : path.split(".").last.tr("_", " ").titleize,
            before: before_value(proposal, operation),
            after: after_value(proposal, operation),
            source_basis: operation.fetch("source_basis"),
            evidence_quote: operation.fetch("evidence_quote")
          }
        end.group_by { |change| change.fetch(:group) }.map do |group, changes|
          { group:, changes: }
        end
      end

      def before_value(proposal, operation)
        return nil if operation["op"] == "add_phrase"
        return operation["value"] if operation["op"] == "remove_phrase"

        dig_state(proposal.before_state, operation.fetch("path"))
      end

      def after_value(proposal, operation)
        return operation.dig("value", "text") if operation["op"] == "add_phrase"
        return nil if operation["op"] == "remove_phrase"

        dig_state(proposal.after_state, operation.fetch("path"))
      end

      def dig_state(state, path)
        keys = path.split(".")
        return state["description"] if keys == [ "description" ]

        keys.reduce(state.fetch("draft_config")) { |target, key| target.to_h[key] }
      end

      def phrase_label(operation)
        operation["op"] == "remove_phrase" ? "Remove phrase" : "Add phrase"
      end
    end
  end
end
