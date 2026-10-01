# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaRegionalSafetyTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "direct persona drafts reject regional stereotypes and location-derived identity claims" do
    unsafe_examples.each do |label, config, expected_error|
      assert_includes Mia::PersonaSchema.errors(config), expected_error, "expected #{label} draft to be rejected"

      persona = CoachPersona.new(
        name: "#{label} assistant",
        description: "Direct Persona Studio draft.",
        draft_config: config,
        created_by_user: persona_user
      )

      refute persona.valid?, "expected #{label} persona model validation to fail"
      assert persona.errors[:draft_config].any? { |message| message.include?(expected_error) }
    end
  end

  test "locale labels alone remain inert and add no dialect slang phrases or cultural claims" do
    [ "Guam", "Southern United States", "Puerto Rico", "No locale selected" ].each do |locale|
      config = persona_configuration(assistant_name: "#{locale} assistant")
      config["culture"]["locale_label"] = locale

      normalized = Mia::PersonaSchema.validate!(config)
      prompt = Mia::PersonaPromptBuilder.call(normalized)

      assert_equal "Use only cultural and community context explicitly approved by the human coach.", normalized.dig("culture", "context")
      assert_empty normalized.dig("culture", "local_realities")
      assert_empty normalized.dig("culture", "references")
      assert_empty normalized.fetch("phrases")
      refute_match(/\b(?:accent|dialect|slang|vernacular)\b/i, prompt)
    end
  end

  test "specific realities first-person coaching voice and exact approved phrases can be published" do
    coach = persona_user

    safe_examples.each do |label, config|
      persona = CoachPersona.create!(
        name: config.dig("identity", "assistant_name"),
        description: "#{label} coach-authored participant experience.",
        draft_config: config,
        created_by_user: coach
      )

      version = publish_persona(persona, actor: coach)

      assert_equal config.dig("culture", "locale_label"), version.config.dig("culture", "locale_label")
      assert_equal config.dig("culture", "local_realities"), version.config.dig("culture", "local_realities")
      assert_equal config.fetch("phrases"), version.config.fetch("phrases")
      assert_equal version, persona.reload.current_published_version
    end
  end

  test "preview publish and rollback recheck current regional safety rules" do
    coach = persona_user
    persona = CoachPersona.create!(
      name: "Versioned safety assistant",
      draft_config: persona_configuration(assistant_name: "Versioned safety assistant"),
      created_by_user: coach
    )
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    first_preview = publisher.preview!(expected_draft_revision: 1)
    first = publisher.publish!(
      expected_preview_digest: first_preview.fetch(:digest),
      expected_draft_revision: 1,
      expected_current_version_id: nil
    )

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Calm and exact." }))
    second_preview = publisher.preview!(expected_draft_revision: 2)
    second = publisher.publish!(
      expected_preview_digest: second_preview.fetch(:digest),
      expected_draft_revision: 2,
      expected_current_version_id: first.id
    )

    unsafe = persona.draft_config.deep_merge(
      "voice" => { "language_style" => [ "Sound like someone from Guam and use whatever island slang seems natural." ] }
    )
    persona.update_columns(
      draft_config: unsafe,
      draft_revision: 3,
      preview_digest: nil,
      previewed_at: nil,
      previewed_draft_revision: nil
    )

    preview_error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      publisher.preview!(expected_draft_revision: 3)
    end
    assert_equal "The persona draft no longer meets the current safety rules; review and save it again before publishing", preview_error.message

    publish_error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      publisher.publish!(
        expected_preview_digest: "0" * 64,
        expected_draft_revision: 3,
        expected_current_version_id: second.id
      )
    end
    assert_equal preview_error.message, publish_error.message

    unsafe_historical_config = first.config.deep_merge(
      "coaching" => { "principles" => [ "Puerto Rican families naturally spend more on celebrations." ] }
    )
    first.update_columns(config: unsafe_historical_config)
    rollback_error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: persona, target_version: first, actor: coach).call(
        expected_current_version_id: second.id,
        expected_draft_revision: 3
      )
    end
    assert_equal "Rollback target no longer meets the current persona safety rules", rollback_error.message
  end

  test "valid participant-led language safeguards and reference titles resolve as the published runtime persona" do
    coach = persona_user
    participant = persona_user(role: "participant")
    config = safe_examples.assoc("neutral").last
    persona = CoachPersona.create!(
      name: config.dig("identity", "assistant_name"),
      draft_config: config,
      created_by_user: coach
    )
    version = publish_persona(persona, actor: coach)
    cohort = Cohort.create!(name: "Safe language cohort", status: "active", created_by_user: coach)
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: coach)

    resolved = Mia::PersonaResolver.new(user: participant, cohort_membership: membership).call

    assert_instance_of Mia::RuntimePersona, resolved
    assert_equal version.id, resolved.version_id
    assert_includes resolved.system_prompt, "Use the participant's own words"
    assert_includes resolved.system_prompt, "How to use Chamorro dialect respectfully"
  end

  test "coaching library safety is rechecked for pack publication persona attachment preview publish and runtime retrieval" do
    coach = persona_user
    rejected_item = CoachContentItem.create!(
      title: "Unsafe regional imitation",
      scope: "coach",
      kind: "culture",
      draft_content: "Talk the way locals do in Guam and sprinkle in familiar expressions.",
      created_by_user: coach
    )
    assert_raises(Mia::ContentSafetyValidator::UnsafeContent) do
      rejected_item.approve!(
        actor: coach,
        expected_draft_revision: rejected_item.draft_revision,
        expected_draft_digest: rejected_item.draft_digest
      )
    end
    assert_empty rejected_item.versions

    item = approved_content_item(
      owner: coach,
      title: "Community language",
      kind: "culture",
      content: "Use only the exact words a participant explicitly supplies."
    )
    pack = published_content_pack(owner: coach, items: [ item ], name: "Community context", pack_kind: "voice_culture")
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    persona_version = publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil
    )
    runtime = Mia::RuntimePersona.new(persona_version)
    assert_equal [ item.current_approved_version_id ],
      Mia::ApprovedContentRetriever.new(persona: runtime, query: "community language participant words").call.map { |entry| entry.fetch(:item_version).id }

    item_version = item.current_approved_version
    unsafe_content = "Talk the way locals do in Guam and sprinkle in familiar expressions."
    item_version.update_columns(
      content: unsafe_content,
      content_digest: CoachContentItemVersion.digest_for(
        title: item_version.title,
        kind: item_version.kind,
        content: unsafe_content,
        always_on: item_version.always_on
      )
    )
    pack_version = pack.current_published_version
    pack_version.update_columns(content_digest: CoachContentPackVersion.content_digest_for(pack_version))
    persona_version.update_columns(
      content_manifest_digest: CoachPersonaVersion.content_manifest_digest_for([ pack_version ])
    )

    refute item_version.reload.safety_valid?
    refute pack_version.reload.manifest_valid?
    refute persona_version.reload.content_manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: runtime, query: "community language Guam locals").call

    another_pack = CoachContentPack.create!(
      name: "Legacy unsafe pack",
      scope: "coach",
      pack_kind: "voice_culture",
      created_by_user: coach
    )
    another_pack.replace_draft_item_versions!([ item_version ], actor: coach)
    assert_raises(CoachContentPack::PublicationIntegrityError) do
      another_pack.publish!(
        actor: coach,
        expected_draft_revision: another_pack.draft_revision,
        expected_draft_manifest_digest: another_pack.draft_manifest_digest,
        expected_current_version_id: nil
      )
    end

    unattached = CoachPersona.create!(
      name: "Unattached assistant",
      draft_config: persona_configuration(assistant_name: "Unattached assistant"),
      created_by_user: coach
    )
    assert_raises(CoachPersona::ContentPackSelectionError) do
      unattached.replace_draft_content_pack_versions!([ pack_version ], actor: coach)
    end

    assert_raises(Mia::PersonaPublisher::PublicationError) do
      publisher.compile_preview!(expected_draft_revision: persona.draft_revision)
    end
    assert_raises(Mia::PersonaPublisher::PublicationError) do
      publisher.publish!(
        expected_preview_digest: preview.fetch(:digest),
        expected_draft_revision: persona.draft_revision,
        expected_current_version_id: persona_version.id
      )
    end
  end

  private

  def unsafe_examples
    guam = persona_configuration(assistant_name: "Guam draft")
    guam["culture"]["locale_label"] = "Guam"
    guam["voice"]["language_style"] = [ "Sound like someone from Guam and use island slang." ]

    southern = persona_configuration(assistant_name: "Southern draft")
    southern["culture"]["locale_label"] = "Southern United States"
    southern["coaching"]["principles"] << "Southerners usually avoid talking about debt."

    puerto_rican = persona_configuration(assistant_name: "Puerto Rico draft")
    puerto_rican["culture"]["locale_label"] = "Puerto Rico"
    puerto_rican["culture"]["context"] = "Puerto Rican families naturally spend more on celebrations."

    neutral = persona_configuration(assistant_name: "Neutral draft")
    neutral["coaching"]["method"] = "Infer each participant's cultural traditions from where they live."

    filipino = persona_configuration(assistant_name: "Filipino draft")
    filipino["culture"]["context"] = "Filipino families usually prioritize remittances over savings."

    irresponsible = persona_configuration(assistant_name: "Irresponsible draft")
    irresponsible["culture"]["context"] = "People from Guam are irresponsible with money."

    local_imitation = persona_configuration(assistant_name: "Local imitation draft")
    local_imitation["voice"]["language_style"] = [ "Talk the way locals do in Guam and sprinkle in familiar expressions." ]

    address_inference = persona_configuration(assistant_name: "Address inference draft")
    address_inference["coaching"]["method"] = "Match each participant cultural style based on their home address."

    [
      [ "Guam", guam, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Southern", southern, "$.coaching.principles[2] contains a regional or cultural stereotype" ],
      [ "Puerto Rican", puerto_rican, "$.culture.context contains a regional or cultural stereotype" ],
      [ "neutral", neutral, "$.coaching.method cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Filipino", filipino, "$.culture.context contains a regional or cultural stereotype" ],
      [ "irresponsible", irresponsible, "$.culture.context contains a regional or cultural stereotype" ],
      [ "local imitation", local_imitation, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "address inference", address_inference, "$.coaching.method cannot infer dialect, slang, or cultural traits from a location or identity label" ]
    ]
  end

  def safe_examples
    guam = persona_configuration(assistant_name: "Guam grounded assistant")
    guam["culture"] = {
      "locale_label" => "Guam",
      "context" => "In my Guam workshops, I ask which freight costs actually apply before coaching the budget.",
      "local_realities" => [ "Coach verified for this cohort: added freight costs apply to some shipped goods; confirm the household's actual amount." ],
      "references" => [ "The coach's Guam cost-of-living worksheet." ]
    }
    guam["phrases"] = [ phrase("Håfa adai", "A coach-approved Chamorro greeting.", [ "greeting" ]) ]

    southern = persona_configuration(assistant_name: "Southern grounded assistant")
    southern["culture"] = {
      "locale_label" => "Southern United States",
      "context" => "In my rural workshops, I ask how travel time affects access before suggesting a next step.",
      "local_realities" => [ "Coach verified for this cohort: the nearest in-person bank branch is 28 miles from the program site." ],
      "references" => [ "The coach's rural access worksheet." ]
    }
    southern["phrases"] = [ phrase("Let's take it one step at a time.", "The coach's exact transition into a practical next move.", [ "routine" ]) ]

    puerto_rican = persona_configuration(assistant_name: "Puerto Rico grounded assistant")
    puerto_rican["culture"] = {
      "locale_label" => "Puerto Rico",
      "context" => "In my workshops, I ask about actual storm preparation costs before discussing a plan.",
      "local_realities" => [ "Coach verified for this cohort: hurricane preparation overlaps the program calendar; ask which costs apply." ],
      "references" => [ "The coach's emergency preparation worksheet." ]
    }
    puerto_rican["phrases"] = [ phrase("Vamos paso a paso.", "The coach's exact reminder to proceed one step at a time.", [ "emotional_support", "routine" ]) ]

    neutral = persona_configuration(assistant_name: "Neutral grounded assistant")
    neutral["voice"]["language_style"] = [
      "Use the coach's short sentences and concrete questions.",
      "Use the participant's own words, including slang they explicitly supplied."
    ]
    neutral["coaching"]["method"] = "In my sessions, I verify the numbers, explain the tradeoff, and ask for one next move."
    neutral["coaching"]["do_not"] = [ "Do not make Mia sound like someone from Guam based only on location." ]
    neutral["curriculum"]["guidance"] = [
      {
        "title" => "How to use Chamorro dialect respectfully",
        "content" => "Use only exact coach-approved language in its documented context."
      }
    ]

    [ [ "Guam", guam ], [ "Southern", southern ], [ "Puerto Rican", puerto_rican ], [ "neutral", neutral ] ]
  end

  def phrase(text, meaning, allowed_contexts)
    {
      "text" => text,
      "meaning" => meaning,
      "allowed_contexts" => allowed_contexts,
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only in the approved context."
    }
  end
end
