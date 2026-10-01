# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaRuntimeCompatibilityTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "published legacy phrases and voice load through an immutable runtime copy" do
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant")
    persona = create_persona(creator: coach, name: "Legacy runtime")
    version = publish_persona(persona, actor: coach)
    legacy = legacy_configuration(persona.draft_config)
    persist_legacy_config(version, legacy)
    cohort, membership = assigned_cohort(persona, coach:, participant:)
    stored_snapshot = published_snapshot(version)

    resolved = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call
    repeated = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call

    assert_instance_of Mia::RuntimePersona, resolved
    assert_equal version.id, resolved.version_id
    assert_includes resolved.voice_summary, "warm, practical, and lighthearted"
    assert_includes resolved.voice_summary, "Steady and reassuring."
    assert_includes resolved.system_prompt, "Håfa adai"
    assert_match Mia::PersonaSchema::ARTIFACT_ID_PATTERN, resolved.cultural_phrases.sole.fetch("artifact_id")
    assert_equal resolved.cultural_phrases.sole.fetch("artifact_id"), repeated.cultural_phrases.sole.fetch("artifact_id")
    refute_includes resolved.system_prompt, "source_user_id"
    assert_equal stored_snapshot, published_snapshot(version.reload)
    assert_equal cohort.id, membership.cohort_id
  end

  test "legacy participant provenance remains scoped to its exact participant" do
    coach = persona_user(role: "coach")
    source_participant = persona_user(role: "participant")
    other_participant = persona_user(role: "participant")
    persona = create_persona(creator: coach, name: "Legacy participant wording")
    version = publish_persona(persona, actor: coach)
    legacy = persona.draft_config.deep_dup
    legacy["phrases"] = [
      {
        "provenance" => "participant_supplied",
        "source_user_id" => source_participant.id,
        "text" => "My storm-fund check",
        "meaning" => "The participant's own name for reviewing storm savings.",
        "allowed_contexts" => [ "routine" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => "Use only for the participant who supplied it."
      }
    ]
    persist_legacy_config(version, legacy)
    cohort = Cohort.create!(name: "Legacy phrase cohort", status: "active", created_by_user: coach)
    source_membership = cohort.cohort_memberships.create!(user: source_participant, role: "participant")
    other_membership = cohort.cohort_memberships.create!(user: other_participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: coach)

    source_runtime = Mia::PersonaResolver.new(user: source_participant, cohort_membership: source_membership).call
    other_runtime = Mia::PersonaResolver.new(user: other_participant, cohort_membership: other_membership).call
    audience_less = Mia::RuntimePersona.new(version.reload)

    assert_includes source_runtime.system_prompt, "My storm-fund check"
    refute_includes other_runtime.system_prompt, "My storm-fund check"
    refute_includes audience_less.system_prompt, "My storm-fund check"
    assert_equal "participant_supplied", source_runtime.cultural_phrases.sole.fetch("provenance")
    assert_equal source_participant.id, source_runtime.cultural_phrases.sole.fetch("source_user_id")
  end

  test "legacy compatibility never repairs a digest mismatch or unsafe cultural wording" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Unsafe legacy runtime")
    version = publish_persona(persona, actor: coach)
    legacy = persona.draft_config.deep_dup
    legacy["phrases"] = [
      {
        "text" => "Sound like someone from Guam.",
        "meaning" => "An unsafe regional imitation directive.",
        "allowed_contexts" => [ "routine" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => ""
      }
    ]

    version.update_columns(config: legacy)
    assert_raises(Mia::PersonaSchema::InvalidConfiguration) { Mia::RuntimePersona.new(version.reload) }

    persist_legacy_config(version, legacy)
    assert_raises(Mia::PersonaSchema::InvalidConfiguration) { Mia::RuntimePersona.new(version.reload) }
  end

  private

  def legacy_configuration(configuration)
    legacy = configuration.deep_dup
    legacy["voice"] = {
      "tone_traits" => [ "empathetic", "grounded", "humorous" ],
      "energy" => "Steady confidence with a reassuring pace.",
      "accountability_style" => "Ask reflective questions before naming patterns.",
      "language_style" => [ "Use simple conversational language, brief definitions, and light humor." ]
    }
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
    legacy
  end

  def persist_legacy_config(version, configuration)
    version.update_columns(
      config: configuration,
      config_digest: Mia::PersonaRuntimeCompatibility.legacy_digest(configuration)
    )
    version.reload
  end

  def assigned_cohort(persona, coach:, participant:)
    cohort = Cohort.create!(name: "Legacy runtime cohort", status: "active", created_by_user: coach)
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: coach)
    [ cohort, membership ]
  end

  def published_snapshot(version)
    {
      attributes: version.attributes.slice("config", "config_digest", "updated_at"),
      json: CoachPersonaVersion.connection.select_value(
        "SELECT config::text FROM coach_persona_versions WHERE id = #{version.id}"
      )
    }
  end
end
