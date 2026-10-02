# frozen_string_literal: true

module Mia
  module PersonaRelease
    class ReviewRules
      class Error < StandardError; end

      def self.self_review!(workspace:, actor:, self_review:)
        return false unless self_review

        membership = workspace.membership_for(actor)
        owners = workspace.coach_workspace_memberships.where(role: "owner").count
        unless membership&.role == "owner" && owners == 1
          raise Error, "A different workspace owner or reviewer must complete this review"
        end
        true
      end
    end
  end
end
