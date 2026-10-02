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

    def can_edit_proposal?(proposal)
      can_propose? && proposal.proposed_by_user_id == user.id
    end

    def can_review_proposal?(proposal)
      return false unless can_review?
      return true unless proposal.proposed_by_user_id == user.id

      self_review_allowed?
    end

    def permissions
      { view: workspace.present? && workspace.allows?(user, :view), propose: can_propose?, review: can_review?, promote: can_review? }
    end

    private

    attr_reader :user, :workspace

    def self_review_allowed?
      return @self_review_allowed if defined?(@self_review_allowed)

      membership = workspace.membership_for(user)
      @self_review_allowed = membership&.role == "owner" &&
        !workspace.coach_workspace_memberships.where(role: %w[owner reviewer]).where.not(user_id: user.id).exists?
    end
  end
end
