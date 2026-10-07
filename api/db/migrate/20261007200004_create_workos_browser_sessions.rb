class CreateWorkosBrowserSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :workos_browser_login_attempts do |t|
      t.string :state_digest, null: false
      t.string :browser_digest, null: false
      t.string :frontend_origin, null: false
      t.string :return_to, null: false
      t.text :encrypted_verifier, null: false
      t.string :client_id, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :workos_browser_login_attempts, :state_digest, unique: true
    add_index :workos_browser_login_attempts, :expires_at

    create_table :workos_browser_sessions do |t|
      t.string :cookie_digest, null: false
      t.string :frontend_origin, null: false
      t.string :client_id, null: false
      t.string :subject, null: false
      t.string :provider_session_id, null: false
      t.text :encrypted_credentials, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :workos_browser_sessions, :cookie_digest, unique: true
    add_index :workos_browser_sessions, :expires_at
  end
end
