class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :clerk_id, null: false
      t.string :email, null: false
      t.string :first_name
      t.string :last_name
      t.string :role, null: false, default: "participant"
      t.string :invitation_status, null: false, default: "accepted"
      t.datetime :invited_at
      t.datetime :accepted_at
      t.datetime :last_sign_in_at

      t.timestamps
    end

    add_index :users, :clerk_id, unique: true
    add_index :users, "LOWER(email)", unique: true, name: "index_users_on_lower_email"
    add_index :users, :role
    add_index :users, :invitation_status
  end
end
