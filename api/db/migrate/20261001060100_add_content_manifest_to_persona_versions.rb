# frozen_string_literal: true

class AddContentManifestToPersonaVersions < ActiveRecord::Migration[8.1]
  EMPTY_MANIFEST_DIGEST = "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

  def change
    add_column :coach_persona_versions, :content_manifest_digest, :string, null: false, default: EMPTY_MANIFEST_DIGEST
    add_check_constraint :coach_persona_versions,
      "content_manifest_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_persona_versions_content_manifest_sha256"
  end
end
