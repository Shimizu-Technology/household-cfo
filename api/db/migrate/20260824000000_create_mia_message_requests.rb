class CreateMiaMessageRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :mia_message_requests do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :request_key, null: false
      t.string :request_fingerprint, null: false
      t.string :status, null: false, default: "processing"
      t.jsonb :response_payload, null: false, default: {}
      t.integer :response_status
      t.datetime :completed_at

      t.timestamps
    end

    add_index :mia_message_requests, [ :chat_session_id, :request_key ], unique: true
    add_check_constraint :mia_message_requests,
                         "status IN ('processing', 'completed')",
                         name: "mia_message_requests_status_valid"
    add_check_constraint :mia_message_requests,
                         "char_length(request_key) BETWEEN 1 AND 100",
                         name: "mia_message_requests_key_length"
  end
end
