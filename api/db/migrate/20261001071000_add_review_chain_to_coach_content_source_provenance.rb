# frozen_string_literal: true

class AddReviewChainToCoachContentSourceProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :coach_content_source_candidates, :original_proposal_digest, :string, null: false
    add_check_constraint :coach_content_source_candidates,
      "original_proposal_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_content_source_candidates_original_digest_sha256"

    %i[coach_content_item_draft_provenances coach_content_item_version_provenances].each do |table|
      add_column table, :candidate_original_proposal_digest, :string, null: false
      add_column table, :candidate_revision, :integer, null: false
      add_reference table, :accepted_by_user, null: false, foreign_key: { to_table: :users }
      add_column table, :accepted_at, :datetime, null: false
      add_check_constraint table,
        "candidate_original_proposal_digest ~ '^[0-9a-f]{64}$'",
        name: "#{table}_original_digest_sha256"
      add_check_constraint table, "candidate_revision > 0", name: "#{table}_candidate_revision_positive"
    end
  end
end
