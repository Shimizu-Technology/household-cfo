class AllowRetainedBankSourcePrivacyUnlink < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION financial_picture_write_guard() RETURNS trigger AS $$
      DECLARE current_generation integer;
      BEGIN
        SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
        IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
          IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'accounts' THEN
            IF NEW.plaid_account_id IS NULL AND (to_jsonb(NEW) - ARRAY['plaid_account_id', 'updated_at']) = (to_jsonb(OLD) - ARRAY['plaid_account_id', 'updated_at']) THEN
              RETURN NEW;
            END IF;
          END IF;
          IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'transaction_drafts' THEN
            IF (to_jsonb(NEW) - ARRAY['raw_input', 'draft_payload', 'merchant', 'updated_at']) = (to_jsonb(OLD) - ARRAY['raw_input', 'draft_payload', 'merchant', 'updated_at'])
              AND NEW.raw_input IS NULL AND NEW.draft_payload = '{}'::jsonb
              AND (NEW.merchant = OLD.merchant OR (NEW.merchant = 'Source row' AND OLD.status IN ('pending', 'ignored'))) THEN
              RETURN NEW;
            END IF;
          END IF;
          IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'mia_action_drafts' THEN
            IF (to_jsonb(NEW) - ARRAY['source_chat_message_id', 'assistant_chat_message_id', 'metadata', 'updated_at']) = (to_jsonb(OLD) - ARRAY['source_chat_message_id', 'assistant_chat_message_id', 'metadata', 'updated_at'])
              AND (NEW.source_chat_message_id IS NULL OR NEW.source_chat_message_id = OLD.source_chat_message_id)
              AND (NEW.assistant_chat_message_id IS NULL OR NEW.assistant_chat_message_id = OLD.assistant_chat_message_id)
              AND (NEW.metadata - 'review_program_scope') = (OLD.metadata - 'review_program_scope') THEN
              RETURN NEW;
            END IF;
          END IF;
          RAISE EXCEPTION 'financial_generation_stale: reload the current financial picture' USING ERRCODE = '23514';
        END IF;
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME <> 'household_profiles' AND NEW.financial_generation IS DISTINCT FROM OLD.financial_generation THEN
          RAISE EXCEPTION 'financial picture generation cannot change' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retained financial records require source-privacy redaction support"
  end
end
