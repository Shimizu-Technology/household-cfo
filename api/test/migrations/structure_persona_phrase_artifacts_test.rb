# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261001081000_structure_persona_phrase_artifacts"
require_relative "../support/persona_test_helper"

class StructurePersonaPhraseArtifactsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "legacy phrases become sealed artifacts and can be rolled back" do
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
    assert_equal Mia::PersonaSchema.artifact_fingerprint(artifact), artifact.fetch("fingerprint")

    unchanged, changed_again = migration.send(:seal_phrases, sealed, source_user_id: 42)
    assert_equal false, changed_again
    assert_equal sealed, unchanged

    restored, reverted = migration.send(:unseal_phrases, sealed)
    assert reverted
    assert_equal legacy_phrase, restored.fetch("phrases").first
  end
end
