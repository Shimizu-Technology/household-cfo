class CreateCoachLaunchReceipts < ActiveRecord::Migration[8.0]
  def change
    create_table :coach_launch_receipts do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :coach_persona, null: false, foreign_key: true
      t.string :request_key, null: false
      t.string :request_digest, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :coach_launch_receipts, [ :coach_workspace_id, :user_id, :request_key ], unique: true, name: 'coach_launch_receipts_request'
  end
end
