# frozen_string_literal: true

module FinancialDocuments
  # Upload and navigation must offer only a review the participant can finish.
  module StatementAccess
    UNAVAILABLE_MESSAGE = "Statements aren't available for your group yet. Please contact your program team.".freeze

    def self.require!(household:, user:, membership: nil)
      SourceReview::LineApprover::TOOLS.each do |key|
        CohortReleases::OperationAccess.require!(household: household, user: user, membership: membership, key: key)
      end
      true
    end

    def self.available?(**options)
      require!(**options)
    rescue SavingsChallenge::AccessPolicy::Unavailable
      false
    end
  end
end
