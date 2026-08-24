class CreateProviderCallLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_call_leases do |t|
      t.string :provider, null: false
      t.integer :slot, null: false
      t.string :owner_token, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :provider_call_leases, [ :provider, :slot ], unique: true
    add_index :provider_call_leases, [ :provider, :expires_at ]
    add_check_constraint :provider_call_leases, "slot > 0", name: "provider_call_leases_slot_positive"
    add_check_constraint :provider_call_leases,
                         "char_length(provider) BETWEEN 1 AND 64",
                         name: "provider_call_leases_provider_length"
    add_check_constraint :provider_call_leases,
                         "char_length(owner_token) BETWEEN 1 AND 64",
                         name: "provider_call_leases_owner_token_length"
  end
end
