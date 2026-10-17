# frozen_string_literal: true

# Append-only history of who opened or paused the savings challenge for a
# cohort, when, from what state, and why. Expand-only: a new table.
class CreateCohortChallengeAccessEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :cohort_challenge_access_events do |t|
      t.references :cohort, null: false, foreign_key: true
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :cohort_release, foreign_key: true
      t.string :action, null: false
      t.string :actor_role_snapshot, null: false
      t.string :from_state, null: false
      t.string :to_state, null: false
      t.boolean :enabled_before, null: false
      t.boolean :hold_before, null: false
      t.boolean :enabled_after, null: false
      t.boolean :hold_after, null: false
      t.string :reason, null: false
      t.string :request_key, null: false
      t.string :request_fingerprint, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :cohort_challenge_access_events, %i[cohort_id request_key], unique: true, name: "idx_challenge_access_events_request"
    add_index :cohort_challenge_access_events, %i[cohort_id occurred_at id], name: "idx_challenge_access_events_history"
    add_check_constraint :cohort_challenge_access_events, "action IN ('open', 'pause')", name: "challenge_access_events_action_valid"
    add_check_constraint :cohort_challenge_access_events, "char_length(btrim(reason)) BETWEEN 5 AND 500", name: "challenge_access_events_reason_valid"
    add_check_constraint :cohort_challenge_access_events, "request_fingerprint ~ '^[0-9a-f]{64}$' AND char_length(request_key) BETWEEN 1 AND 255", name: "challenge_access_events_request_valid"
  end
end
