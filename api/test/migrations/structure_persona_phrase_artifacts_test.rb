# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261001081000_structure_persona_phrase_artifacts"
require_relative "../support/persona_test_helper"

class StructurePersonaPhraseArtifactsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "legacy phrases become sealed artifacts idempotently" do
    migration = StructurePersonaPhraseArtifacts.new
    legacy = persona_configuration
    legacy_phrase = {
      "text" => "Håfa adai",
      "meaning" => "A documented greeting.",
      "allowed_contexts" => [ "greeting" ],
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only as a greeting."
    }
    legacy["phrases"] = [ legacy_phrase ]

    sealed, changed = migration.send(:seal_phrases, legacy, source_user_id: 42)
    artifact = sealed.fetch("phrases").first

    assert changed
    assert_match Mia::PersonaSchema::ARTIFACT_ID_PATTERN, artifact.fetch("artifact_id")
    assert_equal "coach_authored", artifact.fetch("provenance")
    assert_equal 42, artifact.fetch("source_user_id")
    assert_equal "coach", artifact.fetch("source_role_at_capture")
    assert_equal Mia::PersonaSchema.artifact_fingerprint(artifact), artifact.fetch("fingerprint")

    unchanged, changed_again = migration.send(:seal_phrases, sealed, source_user_id: 42)
    assert_equal false, changed_again
    assert_equal sealed, unchanged
  end

  test "rollback is irreversible before drafts or storage constraints change" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Irreversible phrase migration")
    snapshot = persona.reload.attributes.slice(
      "draft_config",
      "draft_revision",
      "preview_digest",
      "previewed_at",
      "previewed_draft_revision",
      "updated_at"
    )
    constraint_before = phrase_storage_constraint_definition

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      StructurePersonaPhraseArtifacts.new.down
    end

    assert_includes error.message, "cannot be reconstructed faithfully"
    assert_equal snapshot, persona.reload.attributes.slice(*snapshot.keys)
    assert_equal constraint_before, phrase_storage_constraint_definition
  end

  test "near-limit legacy drafts remain storable and schema-valid after sealing" do
    coach = persona_user(role: "coach")
    legacy = near_limit_legacy_configuration(target_bytes: 32_753)
    migration = StructurePersonaPhraseArtifacts.new

    assert_equal 32_753, JSON.generate(legacy).bytesize
    sealed, changed = migration.send(
      :seal_phrases,
      legacy,
      source_user_id: coach.id,
      source_role_at_capture: coach.role
    )
    sealed_bytes = JSON.generate(sealed).bytesize

    assert changed
    assert_operator sealed_bytes, :>, StructurePersonaPhraseArtifacts::LEGACY_STORAGE_MAX_BYTES
    assert_operator sealed_bytes, :<=, Mia::PersonaSchema::MAX_BYTES
    assert_empty Mia::PersonaSchema.errors(sealed)

    persona = CoachPersona.create!(
      name: sealed.dig("identity", "assistant_name"),
      draft_config: sealed,
      created_by_user: coach
    )
    assert_equal 24, persona.reload.draft_config.fetch("phrases").length
  end

  test "migration seals the editable draft without rewriting a published version" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Legacy phrase lifecycle")
    version = publish_persona(persona, actor: coach)
    legacy = persona.draft_config.deep_dup
    legacy["phrases"] = [
      {
        "text" => "Håfa adai",
        "meaning" => "A documented greeting.",
        "allowed_contexts" => [ "greeting" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => "Use only as a greeting."
      }
    ]
    legacy_digest = Digest::SHA256.hexdigest(JSON.generate(legacy))
    persona.update_columns(draft_config: legacy)
    version.update_columns(config: legacy, config_digest: legacy_digest)
    published_snapshot = version.reload.attributes.slice("config", "config_digest", "updated_at")
    published_json = CoachPersonaVersion.connection.select_value(
      "SELECT config::text FROM coach_persona_versions WHERE id = #{version.id}"
    )

    StructurePersonaPhraseArtifacts.new.up

    assert_match Mia::PersonaSchema::ARTIFACT_ID_PATTERN,
      persona.reload.draft_config.dig("phrases", 0, "artifact_id")
    assert_equal published_snapshot, version.reload.attributes.slice("config", "config_digest", "updated_at")
    assert_equal published_json, CoachPersonaVersion.connection.select_value(
      "SELECT config::text FROM coach_persona_versions WHERE id = #{version.id}"
    )
  end

  private

  def phrase_storage_constraint_definition
    CoachPersona.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conname = 'coach_personas_draft_config_bytes'
    SQL
  end

  def near_limit_legacy_configuration(target_bytes:)
    config = persona_configuration(assistant_name: "Near-limit legacy persona")
    config["phrases"] = 24.times.map do |index|
      {
        "text" => "Håfa adai #{index + 1}",
        "meaning" => "A documented exact greeting.",
        "allowed_contexts" => [ "greeting" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => "Use only as a greeting."
      }
    end
    config["coaching"]["do"] = []
    config["culture"]["references"] = []
    config["curriculum"]["guidance"] = []

    append_padding(config, config["coaching"]["do"], maximum: 16, item_max: 400, target_bytes:) do |index, length|
      "Reviewed coaching guidance #{index + 1} ".ljust(length, "x")
    end
    append_padding(config, config["culture"]["references"], maximum: 16, item_max: 300, target_bytes:) do |index, length|
      "Reviewed curriculum reference #{index + 1} ".ljust(length, "x")
    end
    append_padding(config, config["curriculum"]["guidance"], maximum: 20, item_max: 1_200, target_bytes:) do |index, length|
      {
        "title" => "Reviewed lesson #{index + 1}",
        "content" => "General financial curriculum ".ljust(length, "x")
      }
    end
    config
  end

  def append_padding(config, collection, maximum:, item_max:, target_bytes:)
    while collection.length < maximum && JSON.generate(config).bytesize < target_bytes
      index = collection.length
      low = 1
      high = item_max
      best = nil
      while low <= high
        length = (low + high) / 2
        candidate = yield(index, length)
        collection << candidate
        size = JSON.generate(config).bytesize
        collection.pop
        if size <= target_bytes
          best = candidate
          low = length + 1
        else
          high = length - 1
        end
      end
      break unless best

      collection << best
    end
  end
end
