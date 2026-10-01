# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261001082000_structure_persona_voice_choices"
require_relative "../support/persona_test_helper"

class StructurePersonaVoiceChoicesTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "legacy safe voice prose normalizes to reviewed choices idempotently" do
    legacy = persona_configuration
    legacy["voice"] = {
      "tone_traits" => [ "empathetic", "grounded", "humorous" ],
      "energy" => "Steady confidence with a reassuring pace.",
      "accountability_style" => "Ask reflective questions before naming patterns.",
      "language_style" => [ "Use simple conversational language, brief definitions, and light humor." ]
    }
    migration = StructurePersonaVoiceChoices.new

    normalized, changed = migration.send(:normalize_config, legacy)

    assert changed
    assert_equal %w[warm practical lighthearted], normalized.dig("voice", "tone_traits")
    assert_equal "Steady and reassuring.", normalized.dig("voice", "energy")
    assert_equal StructurePersonaVoiceChoices::ACCOUNTABILITY_STYLES[1], normalized.dig("voice", "accountability_style")
    assert_equal [
      "Use plain language.",
      "Prefer conversational language.",
      "Use light humor only when the situation is not sensitive.",
      "Be concise and avoid unnecessary jargon."
    ], normalized.dig("voice", "language_style")
    assert Mia::PersonaSchema.valid?(normalized)

    unchanged, changed_again = migration.send(:normalize_config, normalized)
    assert_equal false, changed_again
    assert_equal normalized, unchanged
  end

  test "unknown legacy prose falls back to conservative reviewed defaults" do
    legacy = persona_configuration
    legacy["voice"] = {
      "tone_traits" => [ "custom magic" ],
      "energy" => "Invent a special energy.",
      "accountability_style" => "Anything goes.",
      "language_style" => [ "Invent a dialect." ]
    }

    normalized, changed = StructurePersonaVoiceChoices.new.send(:normalize_config, legacy)

    assert changed
    assert_equal %w[warm direct respectful], normalized.dig("voice", "tone_traits")
    assert_equal "Calm and focused.", normalized.dig("voice", "energy")
    assert_equal StructurePersonaVoiceChoices::ACCOUNTABILITY_STYLES[0], normalized.dig("voice", "accountability_style")
    assert_equal StructurePersonaVoiceChoices::LANGUAGE_STYLES.first(2), normalized.dig("voice", "language_style")
    assert Mia::PersonaSchema.valid?(normalized)
  end

  test "energy normalization preserves quiet and calm intent before directness" do
    migration = StructurePersonaVoiceChoices.new

    assert_equal "Quiet and unhurried.", migration.send(:normalized_energy, "Direct but quiet and unhurried.")
    assert_equal "Quiet and unhurried.", migration.send(:normalized_energy, "Use a slow, direct delivery.")
    assert_equal "Calm, clear, and concise.", migration.send(:normalized_energy, "Calm and direct.")
    assert_equal "Calm and focused.", migration.send(:normalized_energy, "Keep the energy calm.")
    assert_equal "Direct and energetic.", migration.send(:normalized_energy, "Direct and energetic.")
  end

  test "migration normalizes the editable draft without rewriting a published version" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Legacy voice lifecycle")
    version = publish_persona(persona, actor: coach)
    legacy = persona.draft_config.deep_dup
    legacy["voice"] = {
      "tone_traits" => [ "empathetic", "grounded" ],
      "energy" => "Calm and direct.",
      "accountability_style" => "Ask reflective questions before naming patterns.",
      "language_style" => [ "Use simple conversational language." ]
    }
    legacy_digest = Digest::SHA256.hexdigest(JSON.generate(legacy))
    persona.update_columns(draft_config: legacy)
    version.update_columns(config: legacy, config_digest: legacy_digest)
    published_snapshot = version.reload.attributes.slice("config", "config_digest", "updated_at")
    published_json = CoachPersonaVersion.connection.select_value(
      "SELECT config::text FROM coach_persona_versions WHERE id = #{version.id}"
    )

    StructurePersonaVoiceChoices.new.up

    assert_equal "Calm, clear, and concise.", persona.reload.draft_config.dig("voice", "energy")
    assert_equal published_snapshot, version.reload.attributes.slice("config", "config_digest", "updated_at")
    assert_equal published_json, CoachPersonaVersion.connection.select_value(
      "SELECT config::text FROM coach_persona_versions WHERE id = #{version.id}"
    )
  end
end
