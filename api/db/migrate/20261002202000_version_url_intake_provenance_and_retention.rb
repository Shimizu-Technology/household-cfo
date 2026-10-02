# frozen_string_literal: true

class VersionUrlIntakeProvenanceAndRetention < ActiveRecord::Migration[8.1]
  def up
    %i[coach_content_item_draft_provenances coach_content_item_version_provenances].each do |table|
      add_column table, :provenance_digest_version, :integer, null: false, default: 1
      add_check_constraint table, "provenance_digest_version IN (1, 2)",
        name: "#{table}_digest_version_valid"
    end

    add_column :coach_content_source_url_intakes, :redaction_requested_at, :datetime

    remove_check_constraint :coach_content_source_url_intakes, name: "url_intakes_encrypted_payload_present"
    add_check_constraint :coach_content_source_url_intakes,
      "status = 'deleted' OR redaction_requested_at IS NOT NULL OR " \
        "(encrypted_url_ciphertext IS NOT NULL AND encrypted_url_iv IS NOT NULL AND encrypted_url_auth_tag IS NOT NULL)",
      name: "url_intakes_encrypted_payload_present"

    remove_check_constraint :coach_content_source_url_intakes, name: "url_intakes_source_state_coherent"
    add_check_constraint :coach_content_source_url_intakes,
      "(status = 'registered' AND coach_content_source_id IS NOT NULL) OR " \
        "(status = 'deleted') OR " \
        "(status NOT IN ('registered', 'deleted') AND coach_content_source_id IS NULL)",
      name: "url_intakes_source_state_coherent"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "redacted URL intake rows and versioned provenance digests cannot be represented by the previous schema"
  end
end
