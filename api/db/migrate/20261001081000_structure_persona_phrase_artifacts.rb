# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

class StructurePersonaPhraseArtifacts < ActiveRecord::Migration[8.1]
  class MigrationPersona < ActiveRecord::Base
    self.table_name = "coach_personas"
  end

  class MigrationVersion < ActiveRecord::Base
    self.table_name = "coach_persona_versions"
  end

  def up
    MigrationPersona.find_each do |persona|
      config, changed = seal_phrases(persona.draft_config, source_user_id: persona.created_by_user_id)
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

    MigrationVersion.find_each do |version|
      owner_id = MigrationPersona.where(id: version.coach_persona_id).pick(:created_by_user_id)
      config, changed = seal_phrases(version.config, source_user_id: owner_id || version.published_by_user_id)
      next unless changed

      version.update_columns(config: config, config_digest: config_digest(config), updated_at: Time.current)
    end
  end

  def down
    MigrationPersona.find_each do |persona|
      config, changed = unseal_phrases(persona.draft_config)
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

    MigrationVersion.find_each do |version|
      config, changed = unseal_phrases(version.config)
      next unless changed

      version.update_columns(config: config, config_digest: config_digest(config), updated_at: Time.current)
    end
  end

  private

  def seal_phrases(raw_config, source_user_id:)
    config = raw_config.deep_stringify_keys.deep_dup
    changed = false
    config["phrases"] = Array(config["phrases"]).map do |raw_phrase|
      phrase = raw_phrase.deep_stringify_keys
      if phrase["artifact_id"].present? && phrase["fingerprint"].present?
        phrase
      else
        changed = true
        artifact = phrase.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution").merge(
          "artifact_id" => SecureRandom.uuid,
          "provenance" => "coach_authored",
          "source_user_id" => source_user_id
        )
        artifact["fingerprint"] = fingerprint(artifact)
        artifact
      end
    end
    [ config, changed ]
  end

  def unseal_phrases(raw_config)
    config = raw_config.deep_stringify_keys.deep_dup
    changed = false
    config["phrases"] = Array(config["phrases"]).map do |raw_phrase|
      phrase = raw_phrase.deep_stringify_keys
      if phrase.key?("artifact_id")
        changed = true
        phrase.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution")
      else
        phrase
      end
    end
    [ config, changed ]
  end

  def fingerprint(artifact)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(artifact)).b)
  end

  def config_digest(config)
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
