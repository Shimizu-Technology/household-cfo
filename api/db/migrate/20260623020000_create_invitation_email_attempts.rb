class CreateInvitationEmailAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :invitation_email_attempts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :sent_by_user, foreign_key: { to_table: :users }, index: true
      t.string :status, null: false
      t.string :provider, null: false, default: "resend"
      t.string :provider_message_id
      t.text :error
      t.datetime :attempted_at, null: false
      t.datetime :sent_at
      t.timestamps
    end

    add_index :invitation_email_attempts, [ :user_id, :attempted_at ]
    add_index :invitation_email_attempts, :status
    add_check_constraint :invitation_email_attempts,
      "status IN ('not_sent', 'skipped', 'sent', 'failed')",
      name: "invitation_email_attempts_status_valid"
    add_check_constraint :invitation_email_attempts,
      "status <> 'sent' OR sent_at IS NOT NULL",
      name: "invitation_email_attempts_sent_at_required_when_sent"

    backfill_existing_delivery_logs
    backfill_existing_summary_fields
    remove_column :users, :invitation_email_delivery_log
  end

  def down
    add_column :users, :invitation_email_delivery_log, :jsonb, null: false, default: []

    execute <<~SQL.squish
      UPDATE users
      SET invitation_email_delivery_log = COALESCE(logs.delivery_log, '[]'::jsonb)
      FROM (
        SELECT
          user_id,
          jsonb_agg(
            jsonb_build_object(
              'status', status,
              'attempted_at', attempted_at,
              'sent_at', sent_at,
              'sent_by_user_id', sent_by_user_id,
              'provider', provider,
              'provider_message_id', provider_message_id,
              'error', error
            )
            ORDER BY attempted_at
          ) AS delivery_log
        FROM invitation_email_attempts
        GROUP BY user_id
      ) logs
      WHERE users.id = logs.user_id
    SQL

    drop_table :invitation_email_attempts
  end

  private

  def backfill_existing_delivery_logs
    return unless column_exists?(:users, :invitation_email_delivery_log)

    execute <<~SQL.squish
      INSERT INTO invitation_email_attempts (
        user_id,
        sent_by_user_id,
        status,
        provider,
        provider_message_id,
        error,
        attempted_at,
        sent_at,
        created_at,
        updated_at
      )
      SELECT
        users.id,
        CASE
          WHEN entry.value ->> 'sent_by_user_id' ~ '^\\d+$'
            AND EXISTS (SELECT 1 FROM users senders WHERE senders.id = (entry.value ->> 'sent_by_user_id')::bigint)
            THEN (entry.value ->> 'sent_by_user_id')::bigint
          ELSE NULL
        END,
        CASE
          WHEN entry.value ->> 'status' IN ('not_sent', 'skipped', 'sent', 'failed') THEN entry.value ->> 'status'
          ELSE 'failed'
        END,
        COALESCE(NULLIF(entry.value ->> 'provider', ''), 'resend'),
        NULLIF(entry.value ->> 'provider_message_id', ''),
        NULLIF(entry.value ->> 'error', ''),
        COALESCE(NULLIF(entry.value ->> 'attempted_at', '')::timestamp, users.last_invite_email_attempted_at, users.created_at),
        CASE
          WHEN entry.value ->> 'status' = 'sent' THEN COALESCE(NULLIF(entry.value ->> 'sent_at', '')::timestamp, NULLIF(entry.value ->> 'attempted_at', '')::timestamp, users.last_invite_email_attempted_at, users.created_at)
          ELSE NULLIF(entry.value ->> 'sent_at', '')::timestamp
        END,
        NOW(),
        NOW()
      FROM users
      CROSS JOIN LATERAL jsonb_array_elements(users.invitation_email_delivery_log) AS entry(value)
      WHERE jsonb_typeof(users.invitation_email_delivery_log) = 'array'
        AND users.invitation_email_delivery_log <> '[]'::jsonb
    SQL
  end

  def backfill_existing_summary_fields
    execute <<~SQL.squish
      INSERT INTO invitation_email_attempts (
        user_id,
        sent_by_user_id,
        status,
        provider,
        provider_message_id,
        error,
        attempted_at,
        sent_at,
        created_at,
        updated_at
      )
      SELECT
        users.id,
        CASE
          WHEN users.invitation_email_status = 'sent' THEN users.last_invite_email_sent_by_user_id
          ELSE NULL
        END,
        users.invitation_email_status,
        'resend',
        users.invitation_email_provider_id,
        users.invitation_email_error,
        users.last_invite_email_attempted_at,
        CASE
          WHEN users.invitation_email_status = 'sent' THEN COALESCE(users.last_invite_email_sent_at, users.last_invite_email_attempted_at)
          ELSE NULL
        END,
        NOW(),
        NOW()
      FROM users
      WHERE users.last_invite_email_attempted_at IS NOT NULL
        AND users.invitation_email_status IN ('not_sent', 'skipped', 'sent', 'failed')
        AND NOT EXISTS (
          SELECT 1
          FROM invitation_email_attempts attempts
          WHERE attempts.user_id = users.id
        )
    SQL
  end
end
