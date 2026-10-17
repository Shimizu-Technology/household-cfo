# frozen_string_literal: true

module Mia
  module PersonaRelease
    class ReviewRules
      class Error < StandardError; end

      def self.self_review!(workspace:, actor:, self_review:)
        return false unless self_review

        unless workspace.self_review_authority?(actor)
          raise Error, "A different workspace owner or reviewer must complete this review"
        end
        true
      end
    end
  end
end
