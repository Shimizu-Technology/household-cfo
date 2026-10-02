# frozen_string_literal: true

module Mia
  class ApprovedPhrasePolicy
    def initialize(user, workspace: nil)
      @user = user
      @workspace = workspace
    end

    def visible_proposals
      return CoachPhraseProposal.none unless workspace&.allows?(user, :view)

      CoachPhraseProposal.where(coach_workspace_id: workspace.id)
    end

    def can_propose?
      workspace.present? && workspace.allows?(user, :edit)
    end

    def can_review?
      workspace.present? && workspace.allows?(user, :review)
    end

    def permissions
      { view: workspace.present? && workspace.allows?(user, :view), propose: can_propose?, review: can_review?, promote: can_review? }
    end

    private

    attr_reader :user, :workspace
  end
end
