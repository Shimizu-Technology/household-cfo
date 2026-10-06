class GuardChatContinuityAcrossFinancialRestarts < ActiveRecord::Migration[8.0]
  def up
    add_column :chat_sessions, :financial_generation, :integer, default: 0, null: false
    add_column :mia_message_requests, :financial_generation, :integer, default: 0, null: false
    execute <<~SQL
      CREATE FUNCTION financial_chat_write_guard() RETURNS trigger AS $$
      DECLARE current_generation integer;
      BEGIN
        SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
        IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
          RAISE EXCEPTION 'financial_generation_stale: chat continuity changed' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER chat_sessions_financial_picture_guard BEFORE INSERT OR UPDATE ON chat_sessions FOR EACH ROW EXECUTE FUNCTION financial_chat_write_guard();
    SQL
  end

  def down
    execute "DROP TRIGGER chat_sessions_financial_picture_guard ON chat_sessions"
    execute "DROP FUNCTION financial_chat_write_guard()"
    remove_column :chat_sessions, :financial_generation
    remove_column :mia_message_requests, :financial_generation
  end
end
