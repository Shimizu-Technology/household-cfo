# frozen_string_literal: true

module Mia
  class ActionDraftScope
    Mismatch = Class.new(ArgumentError)

    def self.records(relation, user:, membership:, runtime: nil)
      selected = SavingsChallenge::ProgramMode.scope_cohort_id(user: user, membership: membership, runtime: runtime)
      joined = relation.left_outer_joins(source_chat_message: :chat_session)
      stored = "mia_action_drafts.metadata->'review_program_scope'"
      no_stored_scope = "NOT COALESCE(#{stored} ? 'cohort_id', FALSE)"
      if selected
        joined.where("(#{stored}->'cohort_id' = :cohort::jsonb AND #{stored}->'user_id' = :actor::jsonb) OR (#{no_stored_scope} AND chat_sessions.cohort_id = :cohort_id AND chat_sessions.user_id = :actor_id)",
          cohort: selected.to_json, actor: user.id.to_json, cohort_id: selected, actor_id: user.id)
      else
        joined.where("#{stored}->'cohort_id' = 'null'::jsonb OR (#{no_stored_scope} AND chat_sessions.cohort_id IS NULL)")
      end
    end

    def self.reviews(household:, user:, membership:, year:, limit:, runtime: nil)
      records(household.mia_action_drafts.reviewable.for_budget_year(year), user: user, membership: membership, runtime: runtime)
        .includes(:mia_action_items).recent_first.limit(limit)
        .map { |draft| HouseholdFinance::MiaActionDraftPresenter.new(draft).call }
    end
    def self.visible?(draft, user:, membership:, runtime: nil)
      origin = draft.source_chat_message&.chat_session
      saved = draft.metadata.to_h["review_program_scope"].to_h
      origin_cohort_id = saved.key?("cohort_id") ? saved["cohort_id"] : origin&.cohort_id
      origin_user_id = saved.key?("user_id") ? saved["user_id"] : origin&.user_id
      selected = SavingsChallenge::ProgramMode.scope_cohort_id(user: user, membership: membership, runtime: runtime)
      origin_cohort_id == selected && (!selected || origin_user_id == user&.id)
    end

    def self.authorize!(draft, user:, membership:, runtime: nil)
      unless visible?(draft, user: user, membership: membership, runtime: runtime)
        raise Mismatch, "Open the program where Mia prepared this review card. Nothing changed."
      end
      return unless SavingsChallenge::ProgramMode.savings?(user: user, membership: membership, runtime: runtime)

      ChatSessionScope.new(household: draft.household, user: user, membership: membership).authorize!
    end
  end
end
