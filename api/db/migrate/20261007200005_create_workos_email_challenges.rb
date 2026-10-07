class CreateWorkosEmailChallenges < ActiveRecord::Migration[8.1]
  def change
    add_column :workos_browser_login_attempts, :popup, :boolean, null: false, default: false
    create_table :workos_email_challenges do |t|
      t.string :challenge_digest, null: false
      t.string :browser_digest, null: false
      t.string :frontend_origin, null: false
      t.string :client_id, null: false
      t.text :encrypted_context, null: false
      t.datetime :expires_at, null: false
      t.datetime :resend_at, null: false
      t.integer :verification_attempts, null: false, default: 0
      t.timestamps
    end
    add_index :workos_email_challenges, :challenge_digest, unique: true
    add_index :workos_email_challenges, :expires_at
  end
end
