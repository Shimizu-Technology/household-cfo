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
end
