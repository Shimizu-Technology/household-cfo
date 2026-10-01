# frozen_string_literal: true

class AddReviewActionToCoachContentSourceProvenance < ActiveRecord::Migration[8.1]
  def change
    %i[coach_content_item_draft_provenances coach_content_item_version_provenances].each do |table|
      add_column table, :candidate_review_action, :string, null: false, default: "accepted"
      change_column_default table, :candidate_review_action, from: "accepted", to: nil
      add_check_constraint table,
        "candidate_review_action = 'accepted'",
        name: "#{table}_review_action_accepted"
    end
  end
end
