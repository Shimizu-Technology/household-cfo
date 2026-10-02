# frozen_string_literal: true

require "digest"
require "json"

module Mia
  module PersonaRelease
    module ReviewAuthority
      module_function

      def snapshot(workspace:, actor:)
        role = current_review_role(workspace: workspace, reviewer: actor)
        raise ArgumentError, "Reviewer no longer has workspace review access" unless role

        permissions = role == "platform_admin" ? CoachWorkspace::PERMISSIONS.fetch("owner") : CoachWorkspace::PERMISSIONS.fetch(role)

        value = {
          "workspace_id" => workspace.id,
          "reviewer_id" => actor.id,
          "role" => role,
          "permissions" => permissions.map(&:to_s).sort
        }
        [ value, digest(value) ]
      end

      def valid?(snapshot, digest_value)
        snapshot.is_a?(Hash) && snapshot.present? && digest_value.present? &&
          ActiveSupport::SecurityUtils.secure_compare(digest_value, digest(snapshot))
      end

      def currently_authorized?(workspace:, reviewer:)
        current_review_role(workspace: workspace, reviewer: reviewer).present?
      end

      def current_review_role(workspace:, reviewer:)
        return nil unless reviewer&.id

        role, invitation_status, clerk_id = User.where(id: reviewer.id).pick(:role, :invitation_status, :clerk_id)
        return nil unless role.in?(%w[admin coach]) && invitation_status == "accepted"
        return nil if clerk_id.blank? || clerk_id.start_with?("pending_")
        return "platform_admin" if role == "admin"

        membership_role = CoachWorkspaceMembership.where(
          coach_workspace_id: workspace.id,
          user_id: reviewer.id
        ).pick(:role)
        return membership_role if CoachWorkspace::PERMISSIONS.fetch(membership_role, []).include?(:review)

        nil
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(PhraseManifest.canonicalize(value)).b)
      end
    end
  end
end
