# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaRuntimeCompatibilityTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "unpersisted version cannot become a runtime even with a schema valid config" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Transient version")
    transient = persona.versions.build(
      config: persona.draft_config,
      config_digest: "0" * 64,
      sealed_at: Time.current
    )

    error = assert_raises(Mia::PersonaSchema::InvalidConfiguration) do
      Mia::RuntimePersona.new(transient)
    end

    assert_includes error.message, "persisted, sealed publication"
  end

  test "persisted unsealed version cannot become a runtime" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Unsealed version")
    version = publish_persona(persona, actor: coach)
    version.update_columns(sealed_at: nil)
    persona.update_column(:current_published_version_id, nil)

    assert_equal Mia::PersonaSchema.digest(version.config), version.config_digest
    refute version.reload.sealed?
    assert_nil persona.reload.current_published_version_id

    error = assert_raises(Mia::PersonaSchema::InvalidConfiguration) do
      Mia::RuntimePersona.new(version)
    end
    assert_includes error.message, "persisted, sealed publication"
  end

  test "sealed historical legacy and current publications remain usable" do
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant")
    persona = create_persona(creator: coach, name: "Publication history")
    historical = publish_persona(persona, actor: coach)
    persist_legacy_config(historical, legacy_configuration(persona.draft_config))
    persona.update!(
      draft_config: persona.draft_config.deep_merge("identity" => { "assistant_name" => "Current Mia" })
    )
    current = publish_persona(persona, actor: coach)
    _cohort, membership = assigned_cohort(persona, coach:, participant:)

    historical_runtime = Mia::RuntimePersona.new(historical.reload)
    current_runtime = Mia::RuntimePersona.new(current.reload)
    resolved = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call

    assert historical.sealed?
    assert current.sealed?
    assert_includes historical_runtime.system_prompt, "Håfa adai"
    assert_equal "Current Mia", current_runtime.name
    assert_instance_of Mia::RuntimePersona, resolved
    assert_equal current.id, resolved.version_id
  end

  test "versionless draft preview remains available" do
    config = persona_configuration(assistant_name: "Preview Mia", coach_name: "Coach Preview")

    preview = Mia::RuntimePersona.for_preview(config:, persona_id: 91, draft_revision: 7)

    assert_equal "Preview Mia", preview.name
    assert_nil preview.version_id
    assert_equal "runtime_persona:coach_persona_91_draft_7", preview.continuity_id
  end

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
    legacy = legacy_configuration(persona.draft_config)
    legacy["phrases"] = [ persona_phrase_artifact(
      {
        "text" => "My storm-fund check",
        "meaning" => "The participant's own name for reviewing storm savings.",
        "allowed_contexts" => [ "routine" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => "Use only for the participant who supplied it."
      },
      source_user_id: source_participant.id,
      provenance: "participant_supplied"
    ) ]
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

  test "partial provenance never defaults participant wording to coach authored" do
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant")
    persona = create_persona(creator: coach, name: "Ambiguous legacy wording")
    version = publish_persona(persona, actor: coach)
    ambiguous = legacy_configuration(persona.draft_config)
    ambiguous["phrases"] = [
      {
        "source_user_id" => participant.id,
        "text" => "My private savings name",
        "meaning" => "A participant-supplied name.",
        "allowed_contexts" => [ "routine" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare",
        "caution" => "Use only for the participant who supplied it."
      }
    ]
    persist_legacy_config(version, ambiguous)
    _cohort, membership = assigned_cohort(persona, coach:, participant:)

    error = assert_raises(Mia::PersonaSchema::InvalidConfiguration) do
      Mia::RuntimePersona.new(version.reload)
    end
    assert_includes error.message, "artifact_id is required"

    resolved = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call
    assert_instance_of Mia::Persona, resolved
    assert_equal Mia::Persona::NEUTRAL_ID, resolved.id
  end

  test "schema valid published config tampering fails closed before runtime use" do
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant")
    persona = create_persona(creator: coach, name: "Tamper check")
    version = publish_persona(persona, actor: coach)
    _cohort, membership = assigned_cohort(persona, coach:, participant:)
    tampered = version.config.deep_dup
    tampered["identity"]["assistant_name"] = "Tampered Mia"

    assert_raises(ArgumentError) do
      Mia::RuntimePersona.new(version, config: tampered)
    end

    version.update_columns(config: tampered)

    error = assert_raises(Mia::PersonaSchema::InvalidConfiguration) do
      Mia::RuntimePersona.new(version.reload)
    end
    assert_includes error.message, "digest does not match"

    resolved = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call
    assert_instance_of Mia::Persona, resolved
    assert_equal Mia::Persona::NEUTRAL_ID, resolved.id
  end

  test "legacy phrase normalization is stable when the persona owner role changes" do
    coach = persona_user(role: "coach")
    persona = create_persona(creator: coach, name: "Stable legacy provenance")
    version = publish_persona(persona, actor: coach)
    legacy = legacy_configuration(persona.draft_config)
    persist_legacy_config(version, legacy)
    stored_snapshot = published_snapshot(version)

    before = Mia::RuntimePersona.new(version.reload)
    before_artifact = before.all_cultural_phrases.sole.deep_dup
    before_prompt = before.system_prompt

    coach.update!(role: "admin")
    after = Mia::RuntimePersona.new(version.reload)

    assert_equal before_artifact, after.all_cultural_phrases.sole
    assert_equal before_prompt, after.system_prompt
    assert_equal "coach_authored", after.all_cultural_phrases.sole.fetch("provenance")
    assert_equal "coach", after.all_cultural_phrases.sole.fetch("source_role_at_capture")
    assert_equal coach.id, after.all_cultural_phrases.sole.fetch("source_user_id")
    assert_equal stored_snapshot, published_snapshot(version.reload)
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
