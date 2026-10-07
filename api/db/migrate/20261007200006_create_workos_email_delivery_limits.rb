class CreateWorkosEmailDeliveryLimits < ActiveRecord::Migration[8.1]
  def change
    create_table :workos_email_delivery_limits do |t|
      t.string :identity_digest, null: false
      t.datetime :window_started_at, null: false
      t.integer :delivery_count, null: false, default: 0
      t.timestamps
    end
    add_index :workos_email_delivery_limits, :identity_digest, unique: true
    add_index :workos_email_delivery_limits, :updated_at
  end
end
