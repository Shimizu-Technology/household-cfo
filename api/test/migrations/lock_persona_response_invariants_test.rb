# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261001031200_lock_persona_response_invariants"
require_relative "../support/persona_test_helper"

class LockPersonaResponseInvariantsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "backfill locks both response rules and produces the application canonical digest" do
    migration = LockPersonaResponseInvariants.new
    legacy = persona_configuration
    legacy["identity"]["assistant_name"] = "Coach Åsa"
    legacy["response_shape"]["validate_before_coaching"] = false
    legacy["response_shape"]["next_move_required"] = false

    hardened, changed = migration.send(:hardened_config, legacy)

    assert changed
    assert_equal true, hardened.dig("response_shape", "validate_before_coaching")
    assert_equal true, hardened.dig("response_shape", "next_move_required")
    assert_equal false, legacy.dig("response_shape", "validate_before_coaching")
    assert_equal Mia::PersonaSchema.digest(hardened), migration.send(:canonical_digest, hardened)

    unchanged, changed_again = migration.send(:hardened_config, hardened)
    assert_equal false, changed_again
    assert_equal hardened, unchanged
  end

  test "database constraints reject either response rule being disabled" do
    persona = create_persona(name: "Constraint assistant")
    version = publish_persona(persona, actor: persona.created_by_user)

    unsafe_draft = persona.draft_config.deep_dup
    unsafe_draft["response_shape"]["validate_before_coaching"] = false
    assert_raises(ActiveRecord::StatementInvalid) do
      CoachPersona.transaction(requires_new: true) do
        CoachPersona.where(id: persona.id).update_all(draft_config: unsafe_draft)
      end
    end

    unsafe_version = version.config.deep_dup
    unsafe_version["response_shape"]["next_move_required"] = false
    assert_raises(ActiveRecord::StatementInvalid) do
      CoachPersonaVersion.transaction(requires_new: true) do
        CoachPersonaVersion.where(id: version.id).update_all(config: unsafe_version)
      end
    end
  end
end
