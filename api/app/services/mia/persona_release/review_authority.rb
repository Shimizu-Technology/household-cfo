# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    module ReviewAuthority
      module_function

      def snapshot(workspace:, actor:)
        role = actor.admin? ? "platform_admin" : workspace.membership_for(actor)&.role
        raise ArgumentError, "Reviewer no longer has workspace review access" unless workspace.allows?(actor, :review)

        value = {
          "workspace_id" => workspace.id,
          "reviewer_id" => actor.id,
          "role" => role,
          "permissions" => CoachWorkspace::PERMISSIONS.fetch(role, %i[view edit review publish assign manage_members]).map(&:to_s).sort
        }
        [ value, digest(value) ]
      end

      def valid?(snapshot, digest_value)
        snapshot.is_a?(Hash) && snapshot.present? && digest_value.present? &&
          ActiveSupport::SecurityUtils.secure_compare(digest_value, digest(snapshot))
      end

      def currently_authorized?(workspace:, reviewer:)
        workspace.allows?(reviewer, :review)
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(PhraseManifest.canonicalize(value)).b)
      end
    end
  end
end
