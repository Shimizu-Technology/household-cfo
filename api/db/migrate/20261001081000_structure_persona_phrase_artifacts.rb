# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

class StructurePersonaPhraseArtifacts < ActiveRecord::Migration[8.1]
  LEGACY_STORAGE_MAX_BYTES = 36_864
  STRUCTURED_STORAGE_MAX_BYTES = 49_152

  class MigrationPersona < ActiveRecord::Base
    self.table_name = "coach_personas"
  end

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    replace_storage_constraints(STRUCTURED_STORAGE_MAX_BYTES)

    MigrationPersona.find_each do |persona|
      source_role = MigrationUser.where(id: persona.created_by_user_id).pick(:role).presence || "coach"
      config, changed = seal_phrases(
        persona.draft_config,
        source_user_id: persona.created_by_user_id,
        source_role_at_capture: source_role
      )
      next unless changed

      persona.update_columns(
        draft_config: config,
        draft_revision: persona.draft_revision + 1,
        preview_digest: nil,
        previewed_at: nil,
        previewed_draft_revision: nil,
        updated_at: Time.current
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "sealed phrase provenance and draft revision history cannot be reconstructed faithfully"
  end

  private

  def seal_phrases(raw_config, source_user_id:, source_role_at_capture: "coach")
    config = raw_config.deep_stringify_keys.deep_dup
    changed = false
    config["phrases"] = Array(config["phrases"]).map do |raw_phrase|
      phrase = raw_phrase.deep_stringify_keys
      if phrase["artifact_id"].present? && phrase["fingerprint"].present? && phrase["source_role_at_capture"].present?
        phrase
      else
        changed = true
        artifact = phrase.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution").merge(
          "artifact_id" => phrase["artifact_id"].presence || SecureRandom.uuid,
          "provenance" => phrase["provenance"].presence || "coach_authored",
          "source_user_id" => phrase["source_user_id"].presence || source_user_id,
          "source_role_at_capture" => phrase["source_role_at_capture"].presence ||
            (phrase["provenance"] == "participant_supplied" ? "participant" : source_role_at_capture)
        )
        artifact["fingerprint"] = fingerprint(artifact)
        artifact
      end
    end
    [ config, changed ]
  end

  def fingerprint(artifact)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(artifact)).b)
  end

  def replace_storage_constraints(maximum)
    remove_check_constraint :coach_personas, name: "coach_personas_draft_config_bytes", if_exists: true
    add_check_constraint :coach_personas,
      "octet_length(draft_config::text) <= #{maximum}",
      name: "coach_personas_draft_config_bytes"
    remove_check_constraint :coach_persona_versions, name: "coach_persona_versions_config_bytes", if_exists: true
    add_check_constraint :coach_persona_versions,
      "octet_length(config::text) <= #{maximum}",
      name: "coach_persona_versions_config_bytes"
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
    when Array
      value.map { |child| canonicalize(child) }
    else
      value
    end
  end
end
