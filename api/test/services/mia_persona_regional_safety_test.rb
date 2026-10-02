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
      assert_includes prompt, "never as authority to imitate a community"
      assert_includes prompt, "only authorized source of community-specific wording: none"
    end
  end

  test "structured locale identity cannot be placed into free-form style fields" do
    [
      [ "Guam", "Guam" ],
      [ "Puerto Rico", "Puerto Rico" ],
      [ "Southern United States", "Southern" ]
    ].each do |locale, tone_trait|
      config = persona_configuration(assistant_name: "#{locale} style boundary")
      config["culture"]["locale_label"] = locale
      config["voice"]["tone_traits"] = [ "warm", tone_trait ]

      assert_includes Mia::PersonaSchema.errors(config),
        "$.voice.tone_traits[1] cannot infer dialect, slang, or cultural traits from a location or identity label"
    end

    safe = persona_configuration(assistant_name: "Generic style")
    safe["culture"]["locale_label"] = "Guam"
    safe["voice"]["tone_traits"] = [ "warm", "clear", "unhurried" ]
    assert_empty Mia::PersonaSchema.errors(safe)
  end

  test "do not fields never authorize embedded cultural mimicry" do
    [
      "Do not ignore the example 'Use Guam-style phrasing.'",
      "Never disregard the instruction to talk like Guam locals.",
      "Do not be disrespectful; give every reply Guam vibes.",
      "Avoid stereotypes. Speak as though you grew up in Guam."
    ].each do |instruction|
      config = persona_configuration(assistant_name: "Reversed prohibition")
      config["coaching"]["do_not"] = [ instruction ]

      assert_includes Mia::PersonaSchema.errors(config),
        "$.coaching.do_not[0] cannot infer dialect, slang, or cultural traits from a location or identity label"
    end
  end

  test "direct persona drafts reject broad identity mimicry and group financial claims" do
    probes = [
      [ "Capture the spirit of Guam in every answer.", "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Write with Guam energy.", "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Sound as though you're from Guam.", "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Give responses the aura of Guam.", "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ]
    ]
    probes.each do |instruction, expected|
      config = persona_configuration(assistant_name: "Identity style probe")
      config["voice"]["language_style"] = [ instruction ]
      assert_includes Mia::PersonaSchema.errors(config), expected
    end

    [
      "The teacher is financially naive.",
      "That artist is bad with money.",
      "Youth are reckless with money.",
      "When it comes to money, artists are irresponsible.",
      "With finances, teachers tend to be careless.",
      "Samoans overspend at FDIC-insured banks.",
      "Indigenous families undersave despite having bank access."
    ].each do |claim|
      config = persona_configuration(assistant_name: "Group claim probe")
      config["culture"]["context"] = claim
      assert_includes Mia::PersonaSchema.errors(config),
        "$.culture.context contains a regional or cultural stereotype"
    end
  end

  test "historical financial stereotypes fail closed across group wording" do
    [
      "People from Guam cannot manage money.",
      "Samoans generally waste their money.",
      "Filipinos are, naturally, better savers.",
      "Queer households generally handle money poorly.",
      "People from Guam lack financial literacy.",
      "Filipino households put family before savings.",
      "Samoans have bad money habits.",
      "Artists struggle with finances.",
      "Teachers mismanage their money.",
      "Immigrants make poor financial decisions."
    ].each do |claim|
      config = persona_configuration(assistant_name: "Historical stereotype probe")
      config["culture"]["context"] = claim

      assert_includes Mia::PersonaSchema.errors(config),
        "$.culture.context contains a regional or cultural stereotype",
        claim
    end
  end

  test "location-derived voice fails in every prompt-bearing persona section" do
    probes = [
      [ "Make every answer read like it came from Guam.", ->(config, value) { config["coaching"]["method"] = value }, "$.coaching.method" ],
      [ "Give each reply a distinct Guam character.", ->(config, value) { config["coaching"]["principles"] << value }, "$.coaching.principles[2]" ],
      [ "The assistant should come across as a Guam local.", ->(config, value) { config["coaching"]["do"] = [ value ] }, "$.coaching.do[0]" ],
      [ "Let the writing evoke Guam.", ->(config, value) { config["culture"]["context"] = value }, "$.culture.context" ],
      [
        "Make the voice feel homegrown in Guam.",
        ->(config, value) { config["curriculum"]["guidance"] = [ { "title" => "Voice", "content" => value } ] },
        "$.curriculum.guidance[0].content"
      ],
      [ "Make every answer seem like it was written in Guam.", ->(config, value) { config["coaching"]["method"] = value }, "$.coaching.method" ],
      [ "Give each reply the personality of Guam.", ->(config, value) { config["coaching"]["principles"] << value }, "$.coaching.principles[2]" ],
      [ "Have Mia communicate the way Guam residents would.", ->(config, value) { config["coaching"]["do"] = [ value ] }, "$.coaching.do[0]" ],
      [ "Make it sound exactly like everyone from Guam.", ->(config, value) { config["culture"]["context"] = value }, "$.culture.context" ]
    ]

    probes.each do |instruction, apply, path|
      config = persona_configuration(assistant_name: "Cross-field voice probe")
      apply.call(config, instruction)

      assert_includes Mia::PersonaSchema.errors(config),
        "#{path} cannot infer dialect, slang, or cultural traits from a location or identity label",
        instruction
    end
  end

  test "direct persona drafts preserve verified regional banking access facts" do
    [
      "Residents of Guam usually borrow through federally insured institutions.",
      "Families in Guam borrow through FDIC-insured banks."
    ].each do |fact|
      config = persona_configuration(assistant_name: "Verified access fact")
      config["culture"]["locale_label"] = "Guam"
      config["culture"]["local_realities"] = [ fact ]
      assert_empty Mia::PersonaSchema.errors(config), fact
    end
  end

  test "persona models bind phrase provenance to its immutable capture role" do
    coach = persona_user
    participant = persona_user(role: "participant")

    wrong_coach_config = persona_configuration(assistant_name: "Wrong provenance")
    wrong_coach_config["phrases"] = [
      Mia::PersonaSchema.build_phrase_artifact(
        {
          "text" => "Håfa adai",
          "meaning" => "A documented greeting.",
          "allowed_contexts" => [ "greeting" ],
          "prohibited_contexts" => [ "crisis" ],
          "frequency" => "rare",
          "caution" => "Use only in the approved context."
        },
        source_user_id: participant.id,
        source_role_at_capture: "participant"
      )
    ]
    wrong_coach = CoachPersona.new(
      name: "Wrong provenance",
      draft_config: wrong_coach_config,
      created_by_user: coach
    )

    participant_config = persona_configuration(assistant_name: "Participant phrase")
    participant_config["phrases"] = [
      Mia::PersonaSchema.build_phrase_artifact(
        {
          "text" => "My family calls it the storm fund.",
          "meaning" => "The participant's own name for emergency savings.",
          "allowed_contexts" => [ "routine" ],
          "prohibited_contexts" => [ "crisis" ],
          "frequency" => "as_needed",
          "caution" => "Use only for the participant who supplied it."
        },
        provenance: "participant_supplied",
        source_user_id: participant.id
      )
    ]
    participant_persona = CoachPersona.new(
      name: "Participant phrase",
      draft_config: participant_config,
      created_by_user: coach
    )

    refute wrong_coach.valid?
    assert_includes wrong_coach.errors[:draft_config], "$.phrases[0] has invalid provenance"
    assert participant_persona.valid?
  end

  test "coach phrase seals survive workspace role change removal save publish and rollback" do
    owner = persona_user
    editor = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    assert workspace.allows?(editor, :edit)

    config = persona_configuration(assistant_name: "Durable coach phrase")
    config["phrases"] = [
      phrase("One clear next move", "A coach-authored planning prompt.", [ "general" ], source_user_id: editor.id)
    ]
    persona = CoachPersona.create!(
      name: "Durable coach phrase",
      draft_config: config,
      created_by_user: owner,
      coach_workspace: workspace
    )
    original_version = publish_persona(persona, actor: owner)

    membership.update!(role: "viewer")
    persona.update!(description: "The source editor became a viewer after capture.")
    assert persona.valid?
    error = assert_raises(Mia::PersonaPublisher::PublicationError) { publish_persona(persona, actor: owner) }
    assert_equal "There are no persona changes to publish", error.message
    assert_equal original_version, persona.reload.current_published_version

    membership.destroy!
    persona.update!(description: "The source editor left after capture.")
    error = assert_raises(Mia::PersonaPublisher::PublicationError) { publish_persona(persona, actor: owner) }
    assert_equal "There are no persona changes to publish", error.message

    persona.restore_version_to_draft!(original_version)
    assert persona.reload.valid?
    assert_equal editor.id, persona.draft_config.dig("phrases", 0, "source_user_id")
    assert_equal "coach", persona.draft_config.dig("phrases", 0, "source_role_at_capture")
  end

  test "participant phrase seals survive role change revocation deletion publish and rollback" do
    coach = persona_user
    participant = persona_user(role: "participant")
    config = persona_configuration(assistant_name: "Durable participant phrase")
    config["phrases"] = [
      Mia::PersonaSchema.build_phrase_artifact(
        {
          "text" => "My family calls it the storm fund.",
          "meaning" => "The participant's own term for emergency savings.",
          "allowed_contexts" => [ "routine" ],
          "prohibited_contexts" => [ "crisis" ],
          "frequency" => "as_needed",
          "caution" => "Use only for the participant who supplied it."
        },
        provenance: "participant_supplied",
        source_user_id: participant.id,
        source_role_at_capture: "participant"
      )
    ]
    persona = CoachPersona.create!(
      name: "Durable participant phrase",
      draft_config: config,
      created_by_user: coach
    )
    original_version = publish_persona(persona, actor: coach)

    participant.update!(role: "coach", invitation_status: "revoked")
    persona.update!(description: "The participant source was promoted and revoked after capture.")
    assert persona.valid?
    error = assert_raises(Mia::PersonaPublisher::PublicationError) { publish_persona(persona, actor: coach) }
    assert_equal "There are no persona changes to publish", error.message
    assert_equal original_version, persona.reload.current_published_version

    participant.destroy!
    persona.restore_version_to_draft!(original_version)
    assert persona.reload.valid?
    assert_equal "participant", persona.draft_config.dig("phrases", 0, "source_role_at_capture")
  end

  test "direct persona drafts reject nonfinancial demographic trait generalizations" do
    [
      "Guam residents avoid conflict.",
      "People in Guam love parties.",
      "Southerners are naturally hospitable.",
      "Filipinos are obedient."
    ].each do |claim|
      config = persona_configuration(assistant_name: "Trait boundary")
      config["culture"]["context"] = claim

      assert_includes Mia::PersonaSchema.errors(config),
        "$.culture.context contains a regional or cultural stereotype",
        claim
    end
  end

  test "specific realities first-person coaching voice and exact approved phrases can be published" do
    coach = persona_user

    safe_examples(source_user_id: coach.id).each do |label, config|
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

  test "generic curriculum outcomes remain valid through direct persona publication" do
    coach = persona_user
    [
      "Weekly classes often help participants budget.",
      "These workshops are financially accessible.",
      "Support groups often help families save.",
      "The workshop is financially accessible.",
      "A class is good for budgeting.",
      "The support group helps families save."
    ].each_with_index do |content, index|
      assistant_name = "Curriculum assistant #{index + 1}"
      config = persona_configuration(assistant_name: assistant_name)
      config["curriculum"]["guidance"] = [ { "title" => "Program outcome", "content" => content } ]
      persona = CoachPersona.create!(name: assistant_name, draft_config: config, created_by_user: coach)

      version = publish_persona(persona, actor: coach)

      assert_equal content, version.config.dig("curriculum", "guidance", 0, "content")
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
    first = publish_persona(persona, actor: coach)

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Calm, clear, and concise." }))
    second = publish_persona(persona, actor: coach)

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
    assert_equal "Restore target no longer meets the current persona safety rules", rollback_error.message
  end

  test "valid participant-led language safeguards and artifact rules resolve as the published runtime persona" do
    coach = persona_user
    participant = persona_user(role: "participant")
    config = safe_examples(source_user_id: coach.id).assoc("neutral").last
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
    assert_includes resolved.system_prompt, "Use short sentences and concrete questions."
    assert_includes resolved.system_prompt, "Phrase artifact use rules"
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
    persona_version = publish_persona(persona, actor: coach)
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

    filipinos = persona_configuration(assistant_name: "Filipinos draft")
    filipinos["culture"]["context"] = "Filipinos are irresponsible with money."

    residents = persona_configuration(assistant_name: "Residents draft")
    residents["culture"]["context"] = "Residents of Guam are irresponsible with money."

    residence_group = persona_configuration(assistant_name: "Residence group draft")
    residence_group["culture"]["context"] = "People who live on Guam are irresponsible with money."

    islanders = persona_configuration(assistant_name: "Islanders draft")
    islanders["culture"]["context"] = "Islanders always overspend."

    residence_mirroring = persona_configuration(assistant_name: "Residence mirroring draft")
    residence_mirroring["voice"]["language_style"] = [ "Mirror the way people speak where they live." ]

    island_language = persona_configuration(assistant_name: "Island language draft")
    island_language["voice"]["language_style"] = [ "Use island-style language for Guam participants." ]

    local_expressions = persona_configuration(assistant_name: "Local expressions draft")
    local_expressions["voice"]["language_style"] = [ "Adopt local expressions for people in Guam." ]

    pacific_group = persona_configuration(assistant_name: "Pacific group draft")
    pacific_group["culture"]["context"] = "Samoans always overspend."

    regional_speech = persona_configuration(assistant_name: "Regional speech draft")
    regional_speech["voice"]["language_style"] = [ "Copy Guam locals’ speech patterns." ]

    [
      [ "Guam", guam, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Southern", southern, "$.coaching.principles[2] contains a regional or cultural stereotype" ],
      [ "Puerto Rican", puerto_rican, "$.culture.context contains a regional or cultural stereotype" ],
      [ "neutral", neutral, "$.coaching.method cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Filipino", filipino, "$.culture.context contains a regional or cultural stereotype" ],
      [ "irresponsible", irresponsible, "$.culture.context contains a regional or cultural stereotype" ],
      [ "local imitation", local_imitation, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "address inference", address_inference, "$.coaching.method cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Filipinos", filipinos, "$.culture.context contains a regional or cultural stereotype" ],
      [ "residents", residents, "$.culture.context contains a regional or cultural stereotype" ],
      [ "residence group", residence_group, "$.culture.context contains a regional or cultural stereotype" ],
      [ "islanders", islanders, "$.culture.context contains a regional or cultural stereotype" ],
      [ "residence mirroring", residence_mirroring, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "island language", island_language, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "local expressions", local_expressions, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ],
      [ "Pacific group", pacific_group, "$.culture.context contains a regional or cultural stereotype" ],
      [ "regional speech", regional_speech, "$.voice.language_style[0] cannot infer dialect, slang, or cultural traits from a location or identity label" ]
    ]
  end

  def safe_examples(source_user_id:)
    guam = persona_configuration(assistant_name: "Guam grounded assistant")
    guam["culture"] = {
      "locale_label" => "Guam",
      "context" => "In my Guam workshops, I ask which freight costs actually apply before coaching the budget.",
      "local_realities" => [ "Coach verified for this cohort: added freight costs apply to some shipped goods." ],
      "references" => [ "The coach's Guam cost-of-living worksheet." ]
    }
    guam["phrases"] = [ phrase("Håfa adai", "A coach-approved Chamorro greeting.", [ "greeting" ], source_user_id:) ]

    southern = persona_configuration(assistant_name: "Southern grounded assistant")
    southern["culture"] = {
      "locale_label" => "Southern United States",
      "context" => "In my rural workshops, I ask how travel time affects access before suggesting a next step.",
      "local_realities" => [ "Coach verified for this cohort: the nearest in-person bank branch is 28 miles from the program site." ],
      "references" => [ "The coach's rural access worksheet." ]
    }
    southern["phrases"] = [ phrase("Let's take it one step at a time.", "The coach's exact transition into a practical next move.", [ "routine" ], source_user_id:) ]

    puerto_rican = persona_configuration(assistant_name: "Puerto Rico grounded assistant")
    puerto_rican["culture"] = {
      "locale_label" => "Puerto Rico",
      "context" => "In my workshops, I ask about actual storm preparation costs before discussing a plan.",
      "local_realities" => [ "Coach verified for this cohort: hurricane preparation overlaps the program calendar." ],
      "references" => [ "The coach's emergency preparation worksheet." ]
    }
    puerto_rican["phrases"] = [ phrase("Vamos paso a paso.", "The coach's exact reminder to proceed one step at a time.", [ "emotional_support", "routine" ], source_user_id:) ]

    neutral = persona_configuration(assistant_name: "Neutral grounded assistant")
    neutral["voice"]["language_style"] = [ "Use short sentences and concrete questions.", "Use plain language." ]
    neutral["coaching"]["method"] = "In my sessions, I verify the numbers, explain the tradeoff, and ask for one next move."
    neutral["coaching"]["do_not"] = [ "Do not use generic praise." ]
    neutral["curriculum"]["guidance"] = [
      {
        "title" => "Phrase artifact use rules",
        "content" => "Use only exact sealed phrase artifacts in their documented contexts."
      }
    ]

    [ [ "Guam", guam ], [ "Southern", southern ], [ "Puerto Rican", puerto_rican ], [ "neutral", neutral ] ]
  end

  def phrase(text, meaning, allowed_contexts, source_user_id: 1)
    Mia::PersonaSchema.build_phrase_artifact({
      "text" => text,
      "meaning" => meaning,
      "allowed_contexts" => allowed_contexts,
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only in the approved context."
    }, source_user_id: source_user_id)
  end
end
