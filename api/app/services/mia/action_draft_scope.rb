# frozen_string_literal: true

module Mia
  class ActionDraftScope
    Mismatch = Class.new(ArgumentError)
    def self.visible?(draft, user:, membership:)
      origin = draft.source_chat_message&.chat_session
      saved = draft.metadata.to_h["review_program_scope"].to_h
      origin_cohort_id = saved.key?("cohort_id") ? saved["cohort_id"] : origin&.cohort_id
      origin_user_id = saved.key?("user_id") ? saved["user_id"] : origin&.user_id
      selected = membership&.cohort&.savings_challenge_enabled ? membership.cohort_id : nil
      origin_cohort_id == selected && (!selected || origin_user_id == user&.id)
    end

    def self.authorize!(draft, user:, membership:)
      unless visible?(draft, user: user, membership: membership)
        raise Mismatch, "Open the program where Mia prepared this review card. Nothing changed."
      end
      return unless membership&.cohort&.savings_challenge_enabled

      ChatSessionScope.new(household: draft.household, user: user, membership: membership).authorize!
    end
  end
end
