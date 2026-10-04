class ScopeChallengeChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_reference :chat_sessions, :cohort, foreign_key: { on_delete: :restrict }
    remove_index :chat_sessions, name: :index_chat_sessions_on_household_id_and_user_id
    add_index :chat_sessions, [ :household_id, :user_id ], unique: true,
      where: "cohort_id IS NULL", name: :index_chat_sessions_on_household_id_and_user_id
    add_index :chat_sessions, [ :household_id, :user_id, :cohort_id ], unique: true,
      where: "cohort_id IS NOT NULL", name: :index_chat_sessions_on_household_user_cohort

    backfill_attributed_history

    install_scope_guards
  end

  def install_scope_guards
    execute <<~SQL
      CREATE OR REPLACE FUNCTION challenge_chat_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE session_cohort bigint;
      BEGIN
        IF TG_TABLE_NAME = 'chat_sessions' THEN
          IF NEW.household_id IS DISTINCT FROM OLD.household_id OR NEW.user_id IS DISTINCT FROM OLD.user_id
            OR NEW.cohort_id IS DISTINCT FROM OLD.cohort_id THEN
            RAISE EXCEPTION 'conversation actor and program are immutable';
          END IF;
        ELSE
          IF TG_OP = 'UPDATE' AND NEW.chat_session_id IS DISTINCT FROM OLD.chat_session_id THEN
            RAISE EXCEPTION 'message conversation is immutable';
          END IF;
          SELECT cohort_id INTO session_cohort FROM chat_sessions WHERE id = NEW.chat_session_id;
          IF TG_OP = 'UPDATE' AND session_cohort IS NOT NULL AND (
            NEW.cohort_id IS DISTINCT FROM OLD.cohort_id OR NEW.cohort_release_id IS DISTINCT FROM OLD.cohort_release_id
          ) THEN RAISE EXCEPTION 'challenge message release attribution is immutable'; END IF;
          IF session_cohort IS NOT NULL AND (NEW.cohort_id IS DISTINCT FROM session_cohort OR NOT EXISTS (
            SELECT 1 FROM cohort_releases r WHERE r.id = NEW.cohort_release_id AND r.cohort_id = session_cohort
              AND r.tool_registry_version >= 3 AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge'
          )) THEN RAISE EXCEPTION 'message must match its sealed challenge conversation'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      DROP TRIGGER IF EXISTS chat_sessions_scope ON chat_sessions;
      DROP TRIGGER IF EXISTS chat_messages_scope ON chat_messages;
      CREATE TRIGGER chat_sessions_scope BEFORE UPDATE ON chat_sessions FOR EACH ROW EXECUTE FUNCTION challenge_chat_scope_guard();
      CREATE TRIGGER chat_messages_scope BEFORE INSERT OR UPDATE ON chat_messages FOR EACH ROW EXECUTE FUNCTION challenge_chat_scope_guard();
    SQL
  end

  def backfill_attributed_history
    # Only the message's own sealed savings release proves attribution. Mixed
    # summaries and evidence stay in the old session. Cached request responses
    # move only when both actual messages and the complete response prove scope.
    execute <<~SQL
      INSERT INTO chat_sessions (household_id, user_id, cohort_id, title, created_at, updated_at)
      SELECT DISTINCT s.household_id, s.user_id, m.cohort_id, 'Ask Mia', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM chat_sessions s JOIN chat_messages m ON m.chat_session_id = s.id
      JOIN cohort_releases r ON r.id = m.cohort_release_id AND r.cohort_id = m.cohort_id
      WHERE s.cohort_id IS NULL AND r.tool_registry_version >= 3
        AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge'
      ON CONFLICT DO NOTHING;

      UPDATE chat_messages m SET chat_session_id = target.id
      FROM chat_sessions original, chat_sessions target, cohort_releases r
      WHERE m.chat_session_id = original.id AND original.cohort_id IS NULL
        AND target.household_id = original.household_id AND target.user_id = original.user_id
        AND target.cohort_id = m.cohort_id AND r.id = m.cohort_release_id AND r.cohort_id = m.cohort_id
        AND r.tool_registry_version >= 3
        AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge';

      UPDATE mia_message_requests request SET chat_session_id = user_message.chat_session_id
      FROM chat_messages user_message, chat_messages assistant_message, chat_sessions target, chat_sessions original
      WHERE request.chat_session_id = original.id AND original.cohort_id IS NULL AND request.status = 'completed'
        AND request.response_payload->'user_message'->>'id' = user_message.id::text
        AND request.response_payload->'assistant_message'->>'id' = assistant_message.id::text
        AND user_message.chat_session_id = target.id AND assistant_message.chat_session_id = target.id
        AND target.cohort_id IS NOT NULL AND target.household_id = original.household_id AND target.user_id = original.user_id
        AND request.response_payload->'user_message'->>'cohort_id' = target.cohort_id::text
        AND request.response_payload->'assistant_message'->>'cohort_id' = target.cohort_id::text
        AND request.response_payload->'user_message'->>'cohort_release_id' = user_message.cohort_release_id::text
        AND request.response_payload->'assistant_message'->>'cohort_release_id' = assistant_message.cohort_release_id::text
        AND request.response_payload->'user_message'->>'content' = user_message.content
        AND request.response_payload->'assistant_message'->>'content' = assistant_message.content
        AND request.response_payload - ARRAY['user_message', 'assistant_message', 'budget', 'spending_report', 'transaction_draft', 'mia_action_draft', 'savings_intake'] = '{}'::jsonb
        AND COALESCE(request.response_payload->'budget', 'null'::jsonb) = 'null'::jsonb
        AND COALESCE(request.response_payload->'spending_report', 'null'::jsonb) = 'null'::jsonb
        AND COALESCE(request.response_payload->'transaction_draft', 'null'::jsonb) = 'null'::jsonb
        AND COALESCE(request.response_payload->'mia_action_draft', 'null'::jsonb) = 'null'::jsonb;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Scoped conversation requests and evidence cannot safely be merged back into household history"
  end
end
