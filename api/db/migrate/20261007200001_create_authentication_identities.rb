class CreateAuthenticationIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :authentication_identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :issuer, null: false
      t.string :subject, null: false
      t.timestamps
    end
    add_index :authentication_identities, [ :provider, :issuer, :subject ], unique: true, name: "index_auth_identities_on_external_identity"
    add_index :authentication_identities, [ :user_id, :provider, :issuer ], unique: true, name: "index_auth_identities_on_user_provider"
    add_check_constraint :authentication_identities, "provider IN ('clerk', 'workos')", name: "authentication_identities_provider_check"
  end
end
