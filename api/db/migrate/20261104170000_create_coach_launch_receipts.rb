class CreateCoachLaunchReceipts < ActiveRecord::Migration[8.0]
  def change
    create_table :coach_launch_receipts do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :coach_persona, null: false, foreign_key: true
      t.string :request_key, null: false
      t.string :request_digest, null: false
      t.jsonb :result, null: false
      t.timestamps
    end
    add_index :coach_launch_receipts, [ :coach_workspace_id, :user_id, :request_key ], unique: true, name: "coach_launch_receipts_request"
    add_check_constraint :coach_launch_receipts, "char_length(request_key) BETWEEN 1 AND 64", name: "coach_launch_receipts_request_key_bounded"
    add_check_constraint :coach_launch_receipts, "request_digest ~ '^[0-9a-f]{64}$'", name: "coach_launch_receipts_digest_shape"
    add_check_constraint :coach_launch_receipts, "jsonb_typeof(result) = 'object'", name: "coach_launch_receipts_json_shape"
  end
end
