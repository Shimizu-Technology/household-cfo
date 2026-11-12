class PreservePrivateCareHolds < ActiveRecord::Migration[8.0]
  def up
    add_column :chat_sessions, :care_hold, :jsonb, default: {}, null: false
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM chat_sessions WHERE care_hold <> '{}'::jsonb AND active_topic->>'type' IS DISTINCT FROM 'care')")
      raise ActiveRecord::IrreversibleMigration, "A private care hold would be lost. Let active care finish before rolling back."
    end
    remove_column :chat_sessions, :care_hold
  end
end
