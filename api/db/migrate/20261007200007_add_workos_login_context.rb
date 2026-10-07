class AddWorkosLoginContext < ActiveRecord::Migration[8.1]
  def change
    create_table :workos_browser_login_operations do |t|
      t.string :state_digest, null: false
      t.string :browser_digest, null: false
      t.string :frontend_origin, null: false
      t.string :client_id, null: false
      t.datetime :expires_at, null: false
      t.datetime :cancelled_at
      t.datetime :completed_at
      t.string :completed_cookie_digest
      t.timestamps
    end
    add_index :workos_browser_login_operations, :state_digest, unique: true
    add_index :workos_browser_login_operations, :expires_at
    add_column :workos_browser_login_attempts, :encrypted_login_context, :text
    add_reference :workos_browser_login_attempts, :workos_browser_login_operation, foreign_key: true
  end
end
