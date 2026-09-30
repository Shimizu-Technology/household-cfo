# frozen_string_literal: true

require "digest"
require "json"

class LockPersonaResponseInvariants < ActiveRecord::Migration[8.1]
  class MigrationCoachPersona < ActiveRecord::Base
    self.table_name = "coach_personas"
  end

  class MigrationCoachPersonaVersion < ActiveRecord::Base
    self.table_name = "coach_persona_versions"
  end

  PERSONA_CONSTRAINT = "coach_personas_response_invariants_true"
  VERSION_CONSTRAINT = "coach_persona_versions_response_invariants_true"

  def up
    now = Time.current
    backfill_personas(now)
    backfill_versions(now)

    add_check_constraint :coach_personas,
      "(draft_config #> '{response_shape,validate_before_coaching}') IS NOT DISTINCT FROM 'true'::jsonb AND " \
        "(draft_config #> '{response_shape,next_move_required}') IS NOT DISTINCT FROM 'true'::jsonb",
      name: PERSONA_CONSTRAINT
    add_check_constraint :coach_persona_versions,
      "(config #> '{response_shape,validate_before_coaching}') IS NOT DISTINCT FROM 'true'::jsonb AND " \
        "(config #> '{response_shape,next_move_required}') IS NOT DISTINCT FROM 'true'::jsonb",
      name: VERSION_CONSTRAINT
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Persona safety response invariants cannot be restored to false"
  end

  private

  def backfill_personas(now)
    MigrationCoachPersona.find_each do |persona|
      persona.with_lock do
        config, config_changed = hardened_config(persona.draft_config)
        preview_present = persona.preview_digest.present? || persona.previewed_at.present? || persona.previewed_draft_revision.present?
        next unless config_changed || preview_present

        updates = {
          preview_digest: nil,
          previewed_at: nil,
          previewed_draft_revision: nil,
          lock_version: persona.lock_version + 1,
          updated_at: now
        }
        if config_changed
          updates[:draft_config] = config
          updates[:draft_revision] = persona.draft_revision + 1
        end
        persona.update_columns(updates)
      end
    end
  end

  def backfill_versions(now)
    MigrationCoachPersonaVersion.find_each do |version|
      version.with_lock do
        config, changed = hardened_config(version.config)
        next unless changed

        version.update_columns(
          config: config,
          config_digest: canonical_digest(config),
          updated_at: now
        )
      end
    end
  end

  def hardened_config(value)
    config = value.deep_dup
    shape = config["response_shape"]
    return [ config, false ] unless shape.is_a?(Hash)

    changed = shape["validate_before_coaching"] != true || shape["next_move_required"] != true
    if changed
      shape["validate_before_coaching"] = true
      shape["next_move_required"] = true
    end
    [ config, changed ]
  end

  def canonical_digest(config)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(config)).b)
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
