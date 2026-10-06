class AddSetupHelpSupport < ActiveRecord::Migration[8.0]
  def change
    add_column :financial_restart_reviews, :purpose, :string, default: "admin_test", null: false
    add_check_constraint :financial_restart_reviews, "purpose IN ('admin_test','self_setup','supported_setup')", name: "financial_restart_purpose"
    add_column :chat_messages, :setup_help, :jsonb, default: {}, null: false
    create_table :setup_support_requests do |t|
      t.references :household, null: false, foreign_key: true
      t.references :requested_by_user, null: false, foreign_key: { to_table: :users }
      t.references :cohort, foreign_key: true
      t.references :prepared_by_user, foreign_key: { to_table: :users }
      t.references :financial_restart_review, foreign_key: true
      t.bigint :participant_membership_id
      t.datetime :participant_membership_started_at
      t.string :reason, null: false
      t.string :status, default: "requested", null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    add_check_constraint :setup_support_requests, "status IN ('requested','in_review','ready','applied','canceled','declined')", name: "setup_support_status"
    add_check_constraint :setup_support_requests, "reason IN ('practice_numbers','wrong_setup','upload_problem','other')", name: "setup_support_reason"
    add_check_constraint :setup_support_requests, "(cohort_id IS NULL AND participant_membership_id IS NULL AND participant_membership_started_at IS NULL) OR (cohort_id IS NOT NULL AND participant_membership_id IS NOT NULL AND participant_membership_started_at IS NOT NULL)", name: "setup_support_program_identity"
    add_index :setup_support_requests, [ :household_id, :requested_by_user_id, :cohort_id ], name: "setup_support_active_program", unique: true,
      where: "cohort_id IS NOT NULL AND status IN ('requested','in_review','ready')"
    add_index :setup_support_requests, [ :household_id, :requested_by_user_id ], name: "setup_support_active_personal", unique: true,
      where: "cohort_id IS NULL AND status IN ('requested','in_review','ready')"
    add_reference :financial_restart_reviews, :setup_support_request, foreign_key: true
    create_table :setup_help_request_keys do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :setup_support_request, null: false, foreign_key: true
      t.string :idempotency_key, null: false, limit: 200
      t.string :request_fingerprint, null: false
      t.timestamps
    end
    add_index :setup_help_request_keys, [ :household_id, :user_id, :idempotency_key ], unique: true, name: "setup_help_request_identity"
  end
end
