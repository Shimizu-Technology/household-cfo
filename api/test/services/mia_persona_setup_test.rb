# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace, name: "Setup assistant")
    @session = CoachPersonaSetupSession.create!(
      coach_persona: @persona,
      coach_workspace: @workspace,
      created_by_user: @coach,
      base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config),
      last_activity_at: Time.current
    )
  end

  test "operation contract applies exact coach evidence and seals phrase provenance" do
    message = "Call the assistant Lina. Our power bills rise during typhoon season. Use the exact phrase Håfa adai."
    raw = [
      operation("identity.assistant_name", "Lina", evidence: "Lina"),
      operation("culture.local_realities", [ "Our power bills rise during typhoon season." ], evidence: "Our power bills rise during typhoon season."),
      {
        "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai",
        "value" => {
          "text" => "Håfa adai", "meaning" => "A reviewed welcome greeting.",
          "allowed_contexts" => [ "greeting" ], "prohibited_contexts" => [ "crisis" ],
          "frequency" => "rare", "caution" => "Use as a greeting only."
        }
      }
    ]

    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, user_message: message, persona: @persona).build(raw)

    assert_equal "Lina", result.dig(:after_state, "draft_config", "identity", "assistant_name")
    phrase = result.dig(:after_state, "draft_config", "phrases").sole
    assert_equal "coach_authored", phrase.fetch("provenance")
    assert_equal @coach.id, phrase.fetch("source_user_id")
    assert_equal Mia::PersonaSchema.artifact_fingerprint(phrase), phrase.fetch("fingerprint")
  end

  test "operation contract validates only changed community facts" do
    @persona.update!(draft_config: @persona.draft_config.deep_merge("culture" => { "local_realities" => [ "Shipping takes longer to Guam." ] }))
    result = Mia::PersonaSetup::OperationContract.new(
      actor: @coach,
      user_message: "Add: Power restoration can take several days after a typhoon.",
      persona: @persona
    ).build([
      operation(
        "culture.local_realities",
        [ "Shipping takes longer to Guam.", "Power restoration can take several days after a typhoon." ],
        evidence: "Power restoration can take several days after a typhoon."
      )
    ])

    assert_equal 2, result.dig(:after_state, "draft_config", "culture", "local_realities").length
  end

  test "operation contract supports every editable persona field" do
    examples = {
      "description" => "For the second cohort.",
      "identity.assistant_name" => "Lina",
      "identity.human_coach_name" => "Coach Lina",
      "identity.human_coach_title" => "Money coach",
      "identity.assistant_relationship" => "A digital assistant guided by Mrs. Mel's reviewed teaching.",
      "identity.disclosure" => "I am a digital assistant guided by a human financial coach.",
      "identity.audience" => "Adults building a first household spending plan.",
      "identity.client_term" => "household",
      "voice.tone_traits" => [ "warm", "calm" ],
      "voice.energy" => "Warm and encouraging.",
      "voice.accountability_style" => "Use gentle accountability and one practical next step.",
      "voice.language_style" => [ "Use plain language.", "Be concise and avoid unnecessary jargon." ],
      "coaching.philosophy" => "Build confidence through one verified decision at a time.",
      "coaching.method" => "Ask one question, explain the tradeoff, and choose one next step.",
      "coaching.principles" => [ "Verify the facts before giving guidance." ],
      "coaching.do" => [ "Name the practical tradeoff." ],
      "coaching.do_not" => [ "Do not shame the household." ],
      "culture.locale_label" => "Guam households in the first cohort",
      "culture.context" => "Some families send support to relatives across islands.",
      "culture.local_realities" => [ "Shipping can take longer during typhoon recovery." ],
      "culture.references" => [ "The coach calls the spending plan a money map." ],
      "curriculum.guidance" => [ { "title" => "Pause first", "content" => "Verify the amount before deciding." } ],
      "curriculum.scripts" => [ { "title" => "Decision check", "steps" => [ "Verify the amount", "Name the tradeoff" ] } ],
      "curriculum.examples" => [ { "participant" => "Can I afford this?", "assistant" => "Let's verify this month's plan first." } ],
      "response_shape.min_sentences" => 3,
      "response_shape.max_sentences" => 6,
      "response_shape.max_characters" => 1_600,
      "response_shape.plain_text_only" => false
    }
    assert_equal Mia::PersonaSetup::OperationContract::SET_PATHS.sort, examples.keys.sort

    examples.each do |path, value|
      exact = Mia::PersonaSetup::OperationContract::RESTRICTED_EXACT_PATHS.include?(path)
      evidence = if path.start_with?("voice.")
        current = path.split(".").reduce(@persona.draft_config) { |target, key| target.to_h[key] }
        ([ current, value ].flatten.grep(String).uniq).join(" ")
      else
        exact ? Array(value).first.to_s : "approved"
      end
      message = path.start_with?("voice.") ? "approved voice tone #{evidence}" : "approved #{evidence}"
      result = begin
        Mia::PersonaSetup::OperationContract.new(actor: @coach, user_message: message, persona: @persona).build([
          operation(path, value, evidence:)
        ])
      rescue Mia::PersonaSetup::OperationContract::ContractError => error
        flunk "#{path}: #{error.message}"
      end
      state = path == "description" ? result.fetch(:after_state) : result.fetch(:after_state).fetch("draft_config")
      actual = (path == "description" ? [ "description" ] : path.split(".")).reduce(state) { |target, key| target.fetch(key) }
      assert_equal value, actual, path
    end
  end

  test "operation contract rejects protected powers invented evidence and location-derived voice" do
    contract = Mia::PersonaSetup::OperationContract.new(actor: @coach, user_message: "I am from Guam.", persona: @persona)

    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([ operation("response_shape.validate_before_coaching", false, evidence: "Guam") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([ operation("identity.assistant_name", "Invented Mia", evidence: "Guam") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([ operation("voice.tone_traits", [ "warm" ], evidence: "Guam") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach, user_message: "Make it sound Southern.", persona: @persona
      ).build([ operation("voice.tone_traits", [ "warm" ], evidence: "Southern") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach, user_message: "Please adjust the voice.", persona: @persona
      ).build([ operation("voice.tone_traits", [ "calm" ], evidence: "voice") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([
        {
          "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Guam",
          "value" => { "text" => "Invented phrase", "provenance" => "coach_authored" }
        }
      ])
    end
  end

  test "operation contract requires exact coach wording for every changed voice value" do
    previous = Array(@persona.draft_config.dig("voice", "tone_traits"))
    message = "Use a warm and direct tone, replacing #{previous.join(' and ')}."
    result = Mia::PersonaSetup::OperationContract.new(
      actor: @coach,
      user_message: message,
      persona: @persona
    ).build([
      operation("voice.tone_traits", [ "warm", "direct" ], evidence: message)
    ])

    assert_equal %w[warm direct], result.dig(:after_state, "draft_config", "voice", "tone_traits")
  end

  test "operation contract rejects duplicate mutation targets before sealing" do
    contract = Mia::PersonaSetup::OperationContract.new(
      actor: @coach,
      user_message: "Use a warm tone and call the phrase Håfa adai.",
      persona: @persona
    )

    duplicate_set = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([
        operation("description", "First", evidence: "Use"),
        operation("description", "Second", evidence: "Use")
      ])
    end
    assert_match(/more than one change/i, duplicate_set.message)

    phrase = {
      "text" => "Håfa adai", "meaning" => "Greeting", "allowed_contexts" => [ "greeting" ],
      "prohibited_contexts" => [ "crisis" ], "frequency" => "rare", "caution" => ""
    }
    duplicate_phrase = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      contract.build([
        { "op" => "add_phrase", "path" => "phrases", "value" => phrase, "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai" },
        { "op" => "remove_phrase", "path" => "phrases", "value" => "Håfa adai", "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai" }
      ])
    end
    assert_match(/more than one change/i, duplicate_phrase.message)
  end

  test "operation contract cannot remove or rewrite participant phrase artifacts" do
    phrase = persona_phrase_artifact(
      { "text" => "Take it one step at a time." },
      source_user_id: @coach.id,
      provenance: "participant_supplied"
    )
    @persona.update!(draft_config: @persona.draft_config.deep_merge("phrases" => [ phrase ]))

    error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach,
        user_message: "Remove Take it one step at a time.",
        persona: @persona
      ).build([
        {
          "op" => "remove_phrase", "path" => "phrases", "value" => "Take it one step at a time.",
          "source_basis" => "coach_quote", "evidence_quote" => "Take it one step at a time."
        }
      ])
    end

    assert_match(/participant-supplied/i, error.message)
    assert_equal phrase, @persona.reload.draft_config.fetch("phrases").sole
  end

  test "proposal builder rejects a no-op without replacing the pending proposal" do
    original = ready_proposal
    existing_name = @persona.draft_config.dig("identity", "assistant_name")

    error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::ProposalBuilder.new(
        persona: @persona,
        actor: @coach,
        user_message: "Keep the assistant name #{existing_name}."
      ).call([ operation("identity.assistant_name", existing_name, evidence: existing_name) ])
    end

    assert_equal "persona_setup_no_change", error.code
    assert_equal "pending", original.reload.status
    assert_equal 1, @session.proposals.where(status: "pending").count
  end

  test "operation contract rejects an aggregate payload that exceeds the sealed proposal limit" do
    evidence = "approved voice #{'e' * 470}"
    operations = Mia::PersonaSetup::OperationContract::SET_PATHS.first(24).map do |path|
      value = if path == "description"
        @persona.description
      else
        path.split(".").reduce(@persona.draft_config) { |target, key| target.to_h[key] }
      end
      value = 10.times.map { { "participant" => "y" * 600, "assistant" => "z" * 1_200 } } if path == "curriculum.examples"
      operation(path, value, evidence:)
    end

    error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach,
        user_message: evidence,
        persona: @persona
      ).build(operations)
    end

    assert_match(/too large/i, error.message)
  end

  test "only explicitly requested philosophy may be Mia drafted" do
    philosophy = operation("coaching.philosophy", "Build confidence one decision at a time.", source: "mia_drafted", evidence: "")
    result = Mia::PersonaSetup::OperationContract.new(
      actor: @coach, user_message: "Please draft a coaching philosophy.", persona: @persona
    ).build([ philosophy ])
    assert_equal "Build confidence one decision at a time.", result.dig(:after_state, "draft_config", "coaching", "philosophy")

    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach, user_message: "Please draft the teaching curriculum.", persona: @persona
      ).build([ operation("curriculum.guidance", [], source: "mia_drafted", evidence: "") ])
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(
        actor: @coach, user_message: "Please draft a teaching example.", persona: @persona
      ).build([ philosophy ])
    end
  end

  test "context contains only bounded authoring data and strips phrase authority metadata" do
    config = @persona.draft_config.deep_dup
    config["phrases"] = [
      persona_phrase_artifact({ "text" => "Håfa adai" }, source_user_id: @coach.id),
      persona_phrase_artifact(
        { "text" => "My private participant phrase" },
        source_user_id: @coach.id,
        provenance: "participant_supplied"
      )
    ]
    @persona.update!(draft_config: config)
    35.times do |index|
      @session.turns.create!(
        position: index + 1,
        idempotency_key: "context-#{index}",
        status: "failed",
        user_message: "Message #{index}",
        assistant_message: "Nothing changed.",
        error_code: "test"
      )
    end

    context = Mia::PersonaSetup::ContextBuilder.new(session: @session, persona: @persona).call
    phrase = context.dig("authoring_state", "draft_config", "phrases").sole
    assert_equal %w[allowed_contexts caution frequency meaning prohibited_contexts text], phrase.keys.sort
    assert_equal 32, context.fetch("recent_turns").length
    refute_includes JSON.generate(context), @coach.email
    refute_includes JSON.generate(context), "source_user_id"
    refute_includes JSON.generate(context), "fingerprint"
    refute_includes JSON.generate(context), "My private participant phrase"
  end

  test "session serialization bounds the private transcript" do
    105.times do |index|
      @session.turns.create!(
        position: index + 1,
        idempotency_key: "serialized-#{index}",
        status: "failed",
        user_message: "Message #{index}",
        assistant_message: "Nothing changed.",
        error_code: "test"
      )
    end

    payload = Mia::PersonaSetup::Serializer.new(@session).call

    assert_equal true, payload.fetch(:turns_truncated)
    assert_equal 100, payload.fetch(:turns).length
    assert_equal "Message 5", payload.dig(:turns, 0, :user_message)
    assert_equal "Message 104", payload.dig(:turns, -1, :user_message)
  end

  test "turn runner calls provider outside a transaction and applies exactly once" do
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    resolver = fake_resolver do
      assert_equal baseline_transactions, ActiveRecord::Base.connection.open_transactions
      resolver_result("Name updated for review.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    end
    runner = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)

    result = runner.call(user_message: "Call the assistant Lina.", idempotency_key: "turn-key-123")
    replay = runner.call(user_message: "Call the assistant Lina.", idempotency_key: "turn-key-123")

    assert_equal "ready", result.turn.reload.status
    assert_equal result.turn.id, replay.turn.id
    assert_equal result.proposal.id, replay.proposal.id
    assert_equal 1, @session.turns.count
    assert_equal 1, @session.proposals.count

    applier = Mia::PersonaSetup::ProposalApplier.new(proposal: result.proposal, actor: @coach, workspace: @workspace)
    persona = applier.apply!(idempotency_key: "apply-key-123")
    replayed = applier.apply!(idempotency_key: "apply-key-123")
    assert_equal "Lina", persona.name
    assert_equal persona.id, replayed.id
    assert_equal 2, persona.draft_revision
    assert_nil persona.preview_digest
    assert_equal "applied", result.proposal.reload.status
  end

  test "turn reserved on an older persona snapshot stays stale if a pending proposal is applied during provider work" do
    prior = ready_proposal(name: "Lina")
    resolver = fake_resolver do
      Mia::PersonaSetup::ProposalApplier.new(proposal: prior, actor: @coach, workspace: @workspace)
        .apply!(idempotency_key: "apply-during-provider")
      resolver_result(
        "Review this energy.",
        [ operation("voice.energy", "steady", evidence: "steady") ]
      )
    end

    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session, actor: @coach, workspace: @workspace, resolver:
    ).call(user_message: "Use a steady voice energy.", idempotency_key: "snapshot-race-turn")

    assert_equal "Lina", @persona.reload.name
    assert_equal 2, @persona.draft_revision
    assert_equal "stale", result.turn.reload.status
    assert_nil result.proposal
    assert_equal [ prior.id ], @session.proposals.pluck(:id)
  end

  test "turn runner strips unsafe control bytes before persistence and evidence checks" do
    resolver = fake_resolver do
      resolver_result("Review this.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    end

    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver:
    ).call(user_message: "Call\u0000 the assistant Lina.\nPlease.", idempotency_key: "sanitized-turn")

    assert_equal "Call  the assistant Lina.\nPlease.", result.turn.user_message
    refute_includes result.turn.user_message, "\u0000"
  end

  test "manual draft updater stales pending proposals and resets preview" do
    proposal = ready_proposal
    @persona.update_columns(preview_digest: "a" * 64, previewed_at: Time.current, previewed_draft_revision: @persona.draft_revision)
    changed = @persona.draft_config.deep_merge("voice" => { "energy" => "Warm and encouraging." })

    Mia::PersonaDraftUpdater.new(persona: @persona, actor: @coach, workspace: @workspace).call!(
      expected_draft_revision: @persona.draft_revision,
      description: "Manual description",
      draft_config: changed
    )

    assert_equal "stale", proposal.reload.status
    assert_equal @coach, proposal.resolved_by_user
    assert_nil @persona.reload.preview_digest
  end

  test "manual and reviewed chat writes use the same authoring transaction" do
    other_coach = persona_user
    other_workspace = CoachWorkspaces::Resolver.new(user: other_coach).call
    manual_persona = create_persona(creator: other_coach, workspace: other_workspace, name: "Setup assistant")
    method = "Ask one question, explain the tradeoff, and choose one next step."
    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this method.", [ operation("coaching.method", method, evidence: method) ]) }
    ).call(user_message: method, idempotency_key: "parity-chat-turn")
    chat_persona = Mia::PersonaSetup::ProposalApplier.new(
      proposal: result.proposal,
      actor: @coach,
      workspace: @workspace
    ).apply!(idempotency_key: "parity-chat-apply")

    manual_config = manual_persona.draft_config.deep_merge("coaching" => { "method" => method })
    manual_persona = Mia::PersonaDraftUpdater.new(
      persona: manual_persona,
      actor: other_coach,
      workspace: other_workspace
    ).call!(
      expected_draft_revision: manual_persona.draft_revision,
      description: manual_persona.description,
      draft_config: manual_config
    )

    assert_equal Mia::PersonaDraftUpdater.state_for(manual_persona), Mia::PersonaDraftUpdater.state_for(chat_persona)
    assert_equal 2, chat_persona.draft_revision
    assert_equal chat_persona.draft_revision, manual_persona.draft_revision
    assert_nil chat_persona.preview_digest
    assert_nil manual_persona.preview_digest
  end

  test "apply rejects stale tampered archived and demoted state atomically" do
    proposal = ready_proposal
    proposal.update_column(:proposal_digest, "0" * 64)
    applier = Mia::PersonaSetup::ProposalApplier.new(proposal:, actor: @coach, workspace: @workspace)
    error = assert_raises(Mia::PersonaSetup::ProposalApplier::Error) { applier.apply!(idempotency_key: "apply-tampered") }
    assert_equal "persona_setup_stale", error.code
    assert_equal 1, @persona.reload.draft_revision

    proposal.update_column(:proposal_digest, sealed_digest(proposal))
    @workspace.coach_workspace_memberships.find_by!(user: @coach).update!(role: "viewer")
    error = assert_raises(Mia::PersonaSetup::ProposalApplier::Error) { applier.apply!(idempotency_key: "apply-demoted") }
    assert_equal :not_found, error.status
    assert_equal "pending", proposal.reload.status
  end

  test "phrase provenance preserves the authorized role at capture after a staff role change" do
    operation = {
      "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai",
      "value" => {
        "text" => "Håfa adai", "meaning" => "A reviewed welcome greeting.",
        "allowed_contexts" => [ "greeting" ], "prohibited_contexts" => [ "crisis" ],
        "frequency" => "rare", "caution" => "Use as a greeting only."
      }
    }
    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this phrase.", [ operation ]) }
    ).call(user_message: "Use the exact phrase Håfa adai.", idempotency_key: "role-capture-turn")
    @coach.update!(role: "admin")

    persona = Mia::PersonaSetup::ProposalApplier.new(
      proposal: result.proposal,
      actor: @coach,
      workspace: @workspace
    ).apply!(idempotency_key: "role-capture-apply")

    phrase = persona.draft_config.fetch("phrases").sole
    assert_equal "coach", phrase.fetch("source_role_at_capture")
    assert_equal @coach.id, phrase.fetch("source_user_id")
  end

  test "apply reports name collisions and rolls back the persona and proposal atomically" do
    collision_name = "Reserved #{SecureRandom.hex(4)}"
    create_persona(
      creator: @coach,
      workspace: @workspace,
      name: collision_name,
      config: persona_configuration(assistant_name: collision_name)
    )
    proposal = ready_proposal(name: collision_name)
    original_state = Mia::PersonaDraftUpdater.state_for(@persona)

    error = assert_raises(Mia::PersonaSetup::ProposalApplier::Error) do
      Mia::PersonaSetup::ProposalApplier.new(proposal:, actor: @coach, workspace: @workspace)
        .apply!(idempotency_key: "apply-name-collision")
    end

    assert_equal "persona_invalid", error.code
    assert_equal :unprocessable_entity, error.status
    assert_equal original_state, Mia::PersonaDraftUpdater.state_for(@persona.reload)
    assert_equal 1, @persona.draft_revision
    assert_equal "pending", proposal.reload.status
    assert_nil proposal.resolution_idempotency_key
  end

  test "provider payload is strict private and disables fallback collection and tools" do
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: Object.new)
    payload = resolver.payload_for(context: { "authoring_state" => {} }, user_message: "Draft a philosophy")

    assert_equal 0, payload.fetch(:temperature)
    assert_equal [], payload.fetch(:tools)
    assert_equal({ require_parameters: true, allow_fallbacks: false, data_collection: "deny" }, payload.fetch(:provider))
    assert_equal true, payload.dig(:response_format, :json_schema, :strict)
    operation_schema = payload.dig(:response_format, :json_schema, :schema, :properties, :operations, :items)
    assert operation_schema.fetch(:oneOf).all? { |schema| schema[:additionalProperties] == false }
    philosophy_schema = operation_schema.fetch(:oneOf).find { |schema| schema.dig(:properties, "path", :enum) == [ "coaching.philosophy" ] }
    assert_equal %w[coach_quote mia_drafted], philosophy_schema.dig(:properties, "source_basis", :enum)
    operation_schema.fetch(:oneOf).excluding(philosophy_schema).each do |schema|
      assert_equal [ "coach_quote" ], schema.dig(:properties, "source_basis", :enum)
    end
  end

  test "provider rejects fenced output wrong model and admission denial without fallback" do
    fenced = provider_response(model: "exact/model", content: "```json\n{}\n```")
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { fenced })
    assert_equal "persona_setup_invalid", assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver.call(context: {}, user_message: "Hello") }.code

    wrong = provider_response(model: "other/model", content: JSON.generate("assistant_message" => "Review this.", "operations" => []))
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { wrong })
    assert_equal "persona_setup_invalid", assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver.call(context: {}, user_message: "Hello") }.code

    wrong_type = provider_response(model: "exact/model", content: JSON.generate("assistant_message" => 12, "operations" => []))
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { wrong_type })
    assert_equal "persona_setup_invalid", assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver.call(context: {}, user_message: "Hello") }.code

    with_mia_provider_capacity_rejected do
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { flunk "transport must not run" })
      assert_equal "persona_setup_busy", assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver.call(context: {}, user_message: "Hello") }.code
    end
  end

  test "provider rejects assistant messages that falsely claim restricted actions completed" do
    operations = [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]
    [
      "I've published the persona.",
      "I assigned the assistant to the cohort.",
      "The changes have been applied.",
      "The draft is now saved.",
      "The setup is completed.",
      "I updated the assistant name.",
      "I changed the coaching philosophy.",
      "I added the approved phrase.",
      "Your persona is ready to use.",
      "We're updating the assistant tone now.",
      "Mia has set the locale label.",
      "The coaching principles have been revised.",
      "I modified your persona description.",
      "I wrote the coaching philosophy.",
      "Your persona is good to go.",
      "I made the change.",
      "I made the changes.",
      "Your persona is ready.",
      "Removed the phrase.",
      "Your setup is complete.",
      "All set."
    ].each do |message|
      response = provider_response(
        model: "exact/model",
        content: JSON.generate("assistant_message" => message, "operations" => operations)
      )
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

      error = assert_raises(Mia::PersonaSetup::ProposalResolver::Error, message) do
        resolver.call(context: {}, user_message: "Call the assistant Lina.")
      end
      assert_equal "persona_setup_invalid", error.code
    end

    [
      "I prepared one draft change for review. Nothing has been saved.",
      "Your persona draft is ready for review. Apply it only if it looks right.",
      "I changed my mind about the order of these questions.",
      "I changed the tone of this explanation to make it clearer.",
      "I added context below to explain this proposal."
    ].each do |message|
      response = provider_response(
        model: "exact/model",
        content: JSON.generate("assistant_message" => message, "operations" => operations)
      )
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

      assert_equal message, resolver.call(context: {}, user_message: "Call the assistant Lina.").assistant_message
    end
  end

  test "provider usage retains only bounded nonnegative integer token counts" do
    response = provider_response(
      model: "exact/model",
      content: JSON.generate(
        "assistant_message" => "Review this philosophy.",
        "operations" => [ operation("coaching.philosophy", "Build confidence.", source: "mia_drafted", evidence: "") ]
      ),
      usage: {
        "prompt_tokens" => 8,
        "completion_tokens" => -1,
        "total_tokens" => 10_000_001,
        "float_tokens" => 1.5,
        "private" => "discard"
      }
    )
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

    result = resolver.call(context: {}, user_message: "Please draft a coaching philosophy.")

    assert_equal({ "prompt_tokens" => 8 }, result.metadata.fetch("usage"))
    assert_equal "exact/model", result.metadata.fetch("model")
  end

  test "late provider reply after abandon stays stale and creates no proposal" do
    resolver = fake_resolver do
      @session.turns.find_by!(status: "processing").update!(
        status: "stale",
        assistant_message: "This response was stopped because the setup chat changed."
      )
      @session.reload.update!(status: "abandoned")
      resolver_result("This reply arrived late.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    end

    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:).call(
      user_message: "Call the assistant Lina.", idempotency_key: "late-abandon-key"
    )

    assert_equal "stale", result.turn.reload.status
    assert_nil result.proposal
    assert_empty @session.proposals
  end

  test "late provider reply after rebase stays stale and a fresh turn can proceed" do
    resolver = fake_resolver do
      @session.turns.find_by!(status: "processing").update!(
        status: "stale",
        assistant_message: "This response was stopped because the setup chat changed."
      )
      @session.reload.update!(
        base_draft_revision: @persona.draft_revision,
        base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config),
        last_activity_at: Time.current
      )
      resolver_result("This reply arrived late.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    end
    runner = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)

    result = runner.call(user_message: "Call the assistant Lina.", idempotency_key: "late-rebase-key")
    assert_equal "stale", result.turn.reload.status
    assert_empty @session.proposals

    fresh = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]) }
    ).call(user_message: "Call the assistant Lina.", idempotency_key: "fresh-after-rebase")
    assert_equal "ready", fresh.turn.status
  end

  test "reject is exactly once and conflicts on a different resolution key" do
    proposal = ready_proposal
    applier = Mia::PersonaSetup::ProposalApplier.new(proposal:, actor: @coach, workspace: @workspace)

    first = applier.reject!(idempotency_key: "reject-key-123")
    replay = applier.reject!(idempotency_key: "reject-key-123")
    assert_equal first.id, replay.id
    assert_equal "rejected", replay.status

    error = assert_raises(Mia::PersonaSetup::ProposalApplier::Error) do
      applier.reject!(idempotency_key: "reject-key-other")
    end
    assert_equal "persona_setup_resolution_conflict", error.code
  end

  private

  def operation(path, value, source: "coach_quote", evidence:)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => source, "evidence_quote" => evidence }
  end

  def fake_resolver(&block)
    Object.new.tap { |object| object.define_singleton_method(:call) { |**| block.call } }
  end

  def resolver_result(message, operations)
    Mia::PersonaSetup::ProposalResolver::Result.new(
      assistant_message: message,
      operations:,
      metadata: {
        "provider" => "openrouter", "model" => "exact/model",
        "prompt_version" => Mia::PersonaSetup::ProposalBuilder::PROMPT_VERSION,
        "schema_version" => Mia::PersonaSetup::ProposalBuilder::SCHEMA_VERSION,
        "usage" => { "total_tokens" => 12 }
      }
    )
  end

  def ready_proposal(name: "Lina")
    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this name.", [ operation("identity.assistant_name", name, evidence: name) ]) }
    ).call(user_message: "Call the assistant #{name}.", idempotency_key: "ready-#{SecureRandom.hex(6)}")
    result.proposal
  end

  def sealed_digest(proposal)
    Mia::PersonaSetup::ProposalBuilder.digest_for(
      persona: @persona.reload,
      base_draft_revision: proposal.base_draft_revision,
      base_config_digest: proposal.base_config_digest,
      operations: proposal.operations,
      before_state: proposal.before_state,
      after_state: proposal.after_state
    )
  end

  def provider_response(model:, content:, usage: { "total_tokens" => 10 })
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.generate(
      "model" => model,
      "provider" => "test",
      "choices" => [ { "finish_reason" => "stop", "message" => { "content" => content } } ],
      "usage" => usage
    )
    response
  end
end
