# frozen_string_literal: true

class MakePersonaRestoresAndAudienceReviewsAppendOnly < ActiveRecord::Migration[8.0]
  def change
    add_column :coach_persona_versions, :phrase_audience_attestation_digests, :jsonb, null: false, default: []
    add_column :coach_persona_publication_events, :phrase_audience_attestation_digests, :jsonb, null: false, default: []
    reversible do |direction|
      direction.up { backfill_phrase_audience_attestation_digests }
    end
    add_check_constraint :coach_persona_versions,
      "jsonb_typeof(phrase_audience_attestation_digests) = 'array'",
      name: "persona_versions_audience_attestation_digests_array"
    add_check_constraint :coach_persona_publication_events,
      "jsonb_typeof(phrase_audience_attestation_digests) = 'array'",
      name: "persona_publication_events_audience_attestation_digests_array"

    remove_index :coach_phrase_audience_attestations,
      %i[coach_persona_release_candidate_id artifact_id],
      unique: true,
      name: "idx_phrase_audience_attestations_artifact"
    add_index :coach_phrase_audience_attestations,
      %i[coach_persona_release_candidate_id artifact_id reviewed_at id],
      name: "idx_phrase_audience_attestations_effective"

    add_column :coach_persona_behavioral_preview_evidences, :provider_request_id, :string
    add_check_constraint :coach_persona_behavioral_preview_evidences,
      "provider_request_id IS NULL OR char_length(provider_request_id) BETWEEN 1 AND 200",
      name: "persona_behavioral_previews_request_id_bounded"

    create_table :coach_persona_draft_restore_events do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :source_version, null: false, foreign_key: { to_table: :coach_persona_versions }
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.integer :previous_draft_revision, null: false
      t.integer :restored_draft_revision, null: false
      t.string :config_digest, null: false
      t.string :content_manifest_digest, null: false
      t.string :phrase_manifest_digest, null: false
      t.jsonb :content_pack_version_ids, null: false, default: []
      t.jsonb :phrase_artifacts_snapshot, null: false, default: []
      t.string :event_digest, null: false
      t.datetime :restored_at, null: false
      t.timestamps
    end
    add_index :coach_persona_draft_restore_events, :event_digest, unique: true,
      name: "idx_persona_draft_restore_events_digest"
    add_check_constraint :coach_persona_draft_restore_events,
      "previous_draft_revision > 0 AND restored_draft_revision = previous_draft_revision + 1",
      name: "persona_draft_restore_events_revision_sequence"
    add_check_constraint :coach_persona_draft_restore_events,
      "config_digest ~ '^[0-9a-f]{64}$' AND content_manifest_digest ~ '^[0-9a-f]{64}$' AND phrase_manifest_digest ~ '^[0-9a-f]{64}$' AND event_digest ~ '^[0-9a-f]{64}$'",
      name: "persona_draft_restore_events_digest_shape"
    add_check_constraint :coach_persona_draft_restore_events,
      "jsonb_typeof(content_pack_version_ids) = 'array' AND jsonb_typeof(phrase_artifacts_snapshot) = 'array'",
      name: "persona_draft_restore_events_json_shape"
  end

  private

  def backfill_phrase_audience_attestation_digests
    execute <<~SQL.squish
      UPDATE coach_persona_versions versions
      SET phrase_audience_attestation_digests = COALESCE((
        SELECT jsonb_agg(attestations.attestation_digest ORDER BY attestations.artifact_id::text)
        FROM coach_phrase_audience_attestations attestations
        WHERE attestations.coach_persona_release_candidate_id = versions.coach_persona_release_candidate_id
      ), '[]'::jsonb)
      WHERE versions.release_gate_version = 'gate_v2'
    SQL
    execute <<~SQL.squish
      UPDATE coach_persona_publication_events events
      SET phrase_audience_attestation_digests = versions.phrase_audience_attestation_digests
      FROM coach_persona_versions versions
      WHERE versions.id = events.coach_persona_version_id
    SQL
  end
end
