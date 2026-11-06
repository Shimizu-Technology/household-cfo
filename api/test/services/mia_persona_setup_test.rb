# frozen_string_literal: true

require "test_helper"
require_relative "../support/proposal_guard_test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupTest < ActiveSupport::TestCase
  include ProposalGuardTestHelper
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

  test "recorded first coach description preserves supported suggestions and reports unsupported detail" do
    fixture = JSON.parse(file_fixture("persona_setup/coach_voice_response.json").read)
    message = %q(I'm a household money coach on Guam. I talk to my clients like a warm older cousin: direct, practical, never shaming. I start with how they feel, then one clear next step. When someone is about to overspend I say "Chelu, pump the brakes" and suggest waiting 30 days. I protect the basics first: roof, food, utilities, required payments. I keep answers short, 3 or 4 sentences, and I never tell people what to do with their money; I help them decide.)
    before = @persona.draft_config.deep_dup
    result = Mia::PersonaSetup::TurnRunner.new(
      session: @session, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result(fixture.fetch("assistant_message"), fixture.fetch("operations")) }
    ).call(user_message: message, idempotency_key: "recorded-first-voice")

    assert_equal "ready", result.turn.reload.status
    assert_equal 12, result.proposal.operations.length
    assert_equal before.dig("voice", "tone_traits"), result.proposal.after_state.dig("draft_config", "voice", "tone_traits")
    assert_equal fixture.fetch("operations").find { |op| op["path"] == "voice.language_style" }.fetch("value"), result.proposal.after_state.dig("draft_config", "voice", "language_style")
    assert_equal "Chelu, pump the brakes", result.proposal.after_state.dig("draft_config", "phrases").sole.fetch("text")
    assert_equal before, @persona.reload.draft_config
    assert_includes result.turn.assistant_message, "Left out:"
  end

  test "turn preserves valid suggestions and logs a dropped suggestion without coach text" do
    warnings = []
    resolver = fake_resolver do
      resolver_result("Review these suggestions. Nothing has been saved.", [
        operation("identity.assistant_name", "Lina", evidence: "Lina"),
        operation("identity.human_coach_name", "Invented name", evidence: "Lina"),
        operation("response_shape.max_sentences", 4, evidence: "4 sentences")
      ])
    end
    result = nil
    original_logger = Rails.logger
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    begin
      Rails.logger = logger
      result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
        .call(user_message: "Call the assistant Lina. Keep answers to 4 sentences.", idempotency_key: "partial-voice-123")
    ensure
      Rails.logger = original_logger
    end
    assert_equal "ready", result.turn.reload.status
    assert_equal 2, result.proposal.operations.length
    assert_equal "Lina", result.proposal.after_state.dig("draft_config", "identity", "assistant_name")
    assert_equal @persona.draft_config.dig("identity", "human_coach_name"), result.proposal.after_state.dig("draft_config", "identity", "human_coach_name")
    assert_includes result.turn.assistant_message, "Left out: ‘Invented name’"
    assert_includes result.turn.assistant_message, "wording you did not provide"
    assert_match(/contract_code=persona_setup_exact_wording/, warnings.join)
    refute_match(/Lina|Invented name|4 sentences/, warnings.join)
    applied = Mia::PersonaSetup::ProposalApplier.new(proposal: result.proposal, actor: @coach, workspace: @workspace)
      .apply!(idempotency_key: "apply-partial-voice")
    assert_equal "Lina", applied.draft_config.dig("identity", "assistant_name")
    assert_equal 4, applied.draft_config.dig("response_shape", "max_sentences")
  end

  test "entirely invalid suggestions store review notes and preserve the pending proposal" do
    original = ready_proposal
    resolver = fake_resolver { resolver_result("Review this.", [ operation("identity.human_coach_name", "Invented name", evidence: "Lina") ]) }
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
      .call(user_message: "Lina", idempotency_key: "invalid-voice-123")
    assert_equal "ready", result.turn.reload.status
    assert_nil result.proposal
    assert_includes result.turn.assistant_message, "wording you did not provide"
    assert_includes result.turn.assistant_message, "Left out: ‘Invented name’"
    refute_match(/identity\.|Contract|suggestions below/, result.turn.assistant_message)
    assert_equal "pending", original.reload.status
  end

  test "partial validation drops unsafe guidance crisis phrases and participant edits without losing good changes" do
    participant = persona_phrase_artifact({ "text" => "My phrase" }, source_user_id: @coach.id, provenance: "participant_supplied")
    @persona.update!(draft_config: @persona.draft_config.deep_merge("phrases" => [ participant ]))
    phrase = { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Chelu", "value" => {
      "text" => "Chelu", "meaning" => "Pause", "allowed_contexts" => [ "crisis" ], "prohibited_contexts" => [], "frequency" => "rare", "caution" => ""
    } }
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona,
      user_message: "Call the assistant Lina. Chelu. Remove My phrase. Recommend specific stocks.").build_partial([
        operation("identity.assistant_name", "Lina", evidence: "Lina"),
        operation("coaching.do", [ "Recommend specific stocks." ], evidence: "Recommend specific stocks."),
        phrase,
        { "op" => "remove_phrase", "path" => "phrases", "value" => "My phrase", "source_basis" => "coach_quote", "evidence_quote" => "My phrase" }
      ])
    assert_equal 1, result.fetch(:operations).length
    assert_equal 3, result.fetch(:dropped).length
    assert_equal [ participant ], result.dig(:after_state, "draft_config", "phrases")
    assert_equal @persona.draft_config.fetch("coaching"), result.dig(:after_state, "draft_config", "coaching")
  end

  test "partial validation keeps dependent sentence limits despite an unrelated invalid suggestion" do
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Use 6 to 8 sentences. Lina.")
      .build_partial([
        operation("response_shape.min_sentences", 6, evidence: "6 to 8 sentences"),
        operation("identity.human_coach_name", "Invented", evidence: "Lina"),
        operation("response_shape.max_sentences", 8, evidence: "6 to 8 sentences")
      ])
    assert_equal 2, result.fetch(:operations).length
    assert_equal 6, result.dig(:after_state, "draft_config", "response_shape", "min_sentences")
    assert_equal 8, result.dig(:after_state, "draft_config", "response_shape", "max_sentences")
    assert_equal [ 1 ], result.fetch(:dropped).map { |item| item.fetch(:index) }
  end

  test "many dropped suggestions fit the saved reply limit even with a long provider reply" do
    operations = [ operation("identity.assistant_name", "Lina", evidence: "Lina") ] +
      23.times.map { |index| operation("identity.human_coach_name", "Invented #{index}", evidence: "Lina") }
    resolver = fake_resolver { resolver_result("Review this. " * 150, operations) }
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
      .call(user_message: "Lina", idempotency_key: "many-invalid-suggestions")
    assert_equal "ready", result.turn.reload.status
    assert_equal 1, result.proposal.operations.length
    assert_operator result.turn.assistant_message.length, :<=, 2_000
    assert_includes result.turn.assistant_message, "wording you did not provide"
  end

  test "operation contract applies exact coach evidence and seals phrase provenance" do
    message = "Call the assistant Lina. Our power bills rise during typhoon season. Use the exact phrase Håfa adai. A reviewed welcome greeting."
    raw = [
      operation("identity.assistant_name", "Lina", evidence: "Lina"),
      operation("culture.local_realities", [ "Our power bills rise during typhoon season." ], evidence: "Our power bills rise during typhoon season."),
      {
        "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai. A reviewed welcome greeting.",
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

  test "operation contract rejects malformed phrase values with a stable contract error" do
    base = {
      "text" => "Håfa adai", "meaning" => "A reviewed greeting.",
      "allowed_contexts" => [ "greeting" ], "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare", "caution" => "Use only as reviewed."
    }
    malformed_values = [
      "Håfa adai",
      base.except("meaning"),
      base.merge("private" => "not allowed"),
      base.merge("allowed_contexts" => "greeting"),
      base.merge("prohibited_contexts" => [ { "context" => "crisis" } ])
    ]

    malformed_values.each do |value|
      error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        Mia::PersonaSetup::OperationContract.new(
          actor: @coach, user_message: "Use the exact phrase Håfa adai. A reviewed welcome greeting.", persona: @persona
        ).build([ {
          "op" => "add_phrase", "path" => "phrases", "value" => value,
          "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai"
        } ])
      end
      assert_equal "Mia returned an unsupported phrase shape.", error.message
    end
  end

  test "operation contract size projection covers PostgreSQL jsonb text expansion at the database boundary" do
    payload = {}
    index = 0
    while JSON.generate(payload).b.bytesize < Mia::PersonaSetup::OperationContract::MAX_OPERATIONS_BYTES - 128
      payload["field_#{index}"] = index
      index += 1
    end
    payload.delete(payload.keys.last) while JSON.generate(payload).b.bytesize > Mia::PersonaSetup::OperationContract::MAX_OPERATIONS_BYTES

    compact_bytes = JSON.generate(payload).b.bytesize
    connection = ActiveRecord::Base.connection
    postgres_bytes = connection.select_value(
      "SELECT octet_length((#{connection.quote(JSON.generate(payload))})::jsonb::text)"
    ).to_i
    contract = Mia::PersonaSetup::OperationContract.new(actor: @coach, user_message: "approved", persona: @persona)
    projected_bytes = contract.send(:postgres_jsonb_text_upper_bound, payload)

    assert_operator compact_bytes, :<=, Mia::PersonaSetup::OperationContract::MAX_OPERATIONS_BYTES
    assert_operator postgres_bytes, :>, Mia::PersonaSetup::OperationContract::MAX_OPERATIONS_BYTES
    assert_operator projected_bytes, :>=, postgres_bytes
    assert_operator projected_bytes, :>, Mia::PersonaSetup::OperationContract::MAX_OPERATIONS_BYTES
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
        "Remove #{Array(current).map { |item| item.delete_suffix('.').sub(/\A(?:Use|Keep|Prefer|Be|Explain) /, '') }.join(', ')}. Use #{Array(value).join('; ')}"
      else
        if path.start_with?("coaching.", "curriculum.")
          value.is_a?(String) ? value : value.to_json
        else
          exact ? Array(value).first.to_s : "approved"
        end
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

  test "operation contract accepts explicitly replacing previously named voice traits" do
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


  test "review M1 rejects unsupported removal independently of additions" do
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Use a warm and practical tone.")
        .build([ operation("voice.tone_traits", %w[warm direct practical], evidence: "warm and practical tone") ])
    end
  end



  test "review M1 does not treat negated removal requests as removal permission" do
    [ "Use a warm tone. Do not remove respectful.", "No humor, stay respectful and warm." ].each do |quote|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: quote).build([
          operation("voice.tone_traits", %w[warm direct], evidence: quote)
        ])
      end
    end
  end




  test "review m3 accepts brief plain practical descriptions using the same supporting words" do
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona,
      user_message: "I keep it brief, plain and practical.").build([
        operation("voice.tone_traits", %w[warm direct respectful concise practical], evidence: "brief, plain and practical")
      ])
    assert_equal %w[warm direct respectful concise practical], result.dig(:after_state, "draft_config", "voice", "tone_traits")
  end

  test "review M1 supports each production voice choice from its own description and preserves defaults" do
    message = %q(I'm a household money coach on Guam. I talk to my clients like a warm older cousin: direct, practical, never shaming. I start with how they feel, then one clear next step. When someone is about to overspend I say "Chelu, pump the brakes" and suggest waiting 30 days. I protect the basics first: roof, food, utilities, required payments. I keep answers short, 3 or 4 sentences, and I never tell people what to do with their money; I help them decide.)
    quote = message[message.index("warm older cousin")...message.index(", 3 or 4 sentences")]
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([
      operation("voice.tone_traits", %w[warm direct respectful practical concise], evidence: quote),
      operation("voice.accountability_style", "Use gentle accountability and one practical next step.",
        evidence: "never shaming. I start with how they feel, then one clear next step")
    ])
    assert_equal %w[warm direct respectful practical concise], result.dig(:after_state, "draft_config", "voice", "tone_traits")
  end

  test "risk split accepts language preset mappings from a descriptive quote" do
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Use a warm tone. I keep answers short, 3 or 4 sentences.").build([
      operation("voice.language_style", [ "Use plain language.", "Keep the next step concrete.", "Prefer conversational language." ], evidence: "I keep answers short, 3 or 4 sentences")
    ])
    assert_includes result.dig(:after_state, "draft_config", "voice", "language_style"), "Prefer conversational language."
  end

  test "review M1 requires explicit removal and accepts negated respectful synonyms" do
    quote = "Keep it warm and direct, never shaming. Remove the formal tone."
    @persona.update!(draft_config: @persona.draft_config.deep_merge("voice" => { "tone_traits" => %w[warm direct formal] }))
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: quote).build([
      operation("voice.tone_traits", %w[warm direct respectful], evidence: quote)
    ])
    assert_equal %w[warm direct respectful], result.dig(:after_state, "draft_config", "voice", "tone_traits")
  end

  test "review CodeRabbit identity-derived descriptive evidence is rejected" do
    @persona.update!(draft_config: @persona.draft_config.deep_merge("voice" => { "tone_traits" => %w[direct respectful] }))
    error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Use warm Guam locals as the voice.").build([
        operation("voice.tone_traits", %w[warm direct respectful], evidence: "warm Guam locals")
      ])
    end
    assert_equal "persona_setup_voice_evidence", error.code
  end

  test "review m5 names the dropped safety suggestion without leaking it into logs" do
    resolver = fake_resolver { resolver_result("Review this.", [
      operation("identity.assistant_name", "Lina", evidence: "Lina"),
      operation("coaching.do_not", [ "Never skip the crisis protocol" ], evidence: "Never skip the crisis protocol")
    ]) }
    # Force an evidence rejection without loosening the safety contract.
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
      .call(user_message: "Lina", idempotency_key: "review-dropped-safety")
    assert_includes result.turn.assistant_message, "Never skip the crisis protocol"
    assert_equal 1, result.proposal.operations.length
  end

  test "review m5 names a dropped numeric answer setting" do
    resolver = fake_resolver { resolver_result("Review this.", [
      operation("identity.assistant_name", "Lina", evidence: "Lina"),
      operation("response_shape.max_sentences", 1_000, evidence: "1000 sentences")
    ]) }
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
      .call(user_message: "Lina. Use 1000 sentences.", idempotency_key: "review-dropped-length")
    assert_includes result.turn.assistant_message, "Longest answer: 1000 sentences"
    assert_equal 1, result.proposal.operations.length
  end

  test "review m6 provider failures store Nothing changed exactly once" do
    error = assert_raises(Mia::PersonaSetup::TurnRunner::Error) do
      Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
        resolver: fake_resolver { raise Mia::PersonaSetup::ProposalResolver::Error.new("Unavailable", code: "persona_setup_unavailable") })
        .call(user_message: "Call her Lina.", idempotency_key: "review-unavailable")
    end
    assert_equal 1, error.result.turn.reload.assistant_message.scan("Nothing changed.").length
  end

  test "review m7 old prompt versions fail safely with resend guidance" do
    proposal = ready_proposal
    proposal.update_columns(prompt_version: "coach_persona_setup_v1", proposal_digest: "0" * 64)
    error = assert_raises(Mia::PersonaSetup::ProposalApplier::Error) do
      Mia::PersonaSetup::ProposalApplier.new(proposal:, actor: @coach, workspace: @workspace)
        .apply!(idempotency_key: "review-old-prompt")
    end
    assert_includes error.message, "Please send that again"
    assert_equal 1, @persona.reload.draft_revision
    assert_equal "pending", proposal.reload.status
  end

  test "operation contract rejects duplicate mutation targets before sealing" do
    contract = Mia::PersonaSetup::OperationContract.new(
      actor: @coach,
      user_message: "Use a warm tone. Use the exact phrase Håfa adai. Greeting.",
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
        { "op" => "add_phrase", "path" => "phrases", "value" => phrase, "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai. Greeting." },
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
    evidence = "approved voice e #{'e' * 470}"
    operations = Mia::PersonaSetup::OperationContract::SET_PATHS.first(24).map do |path|
      value = if path == "description"
        @persona.description
      else
        path.split(".").reduce(@persona.draft_config) { |target, key| target.to_h[key] }
      end
      value = 10.times.map { { "participant" => ("e " * 300).strip, "assistant" => ("e " * 600).strip } } if path == "curriculum.examples"
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

    built = Mia::PersonaSetup::ProposalBuilder.new(persona: @persona, actor: @coach, user_message: "Call the assistant Lina.")
      .call([ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    turn = @session.turns.create!(position: 36, idempotency_key: "pending-context", status: "ready", assistant_message: "Review this.", user_message: "Call the assistant Lina.")
    CoachPersonaSetupProposal.create!(session: @session, turn:, status: "pending", **built)
    context = Mia::PersonaSetup::ContextBuilder.new(session: @session, persona: @persona).call
    assert_equal 1, context.dig("pending_suggestions", "draft_config", "phrases").length
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

  test "turn runner fails unexpected standard errors and leaves the session available" do
    [ KeyError.new("simulated key failure"), ActiveRecord::StatementInvalid.new("simulated database failure") ].each_with_index do |failure, index|
      runner = Mia::PersonaSetup::TurnRunner.new(
        session: @session,
        actor: @coach,
        workspace: @workspace,
        resolver: fake_resolver { raise failure }
      )
      key = "unexpected-failure-#{index}"

      error = assert_raises(Mia::PersonaSetup::TurnRunner::Error) do
        runner.call(user_message: "Call the assistant Lina.", idempotency_key: key)
      end

      assert_equal "persona_setup_failed", error.code
      assert_equal :service_unavailable, error.status
      assert_equal "failed", error.result.turn.reload.status
      assert_equal "persona_setup_failed", error.result.turn.error_code
      assert_equal true, runner.call(user_message: "Call the assistant Lina.", idempotency_key: key).replayed
      refute @session.turns.where(status: "processing").exists?
    end

    fresh = Mia::PersonaSetup::TurnRunner.new(
      session: @session,
      actor: @coach,
      workspace: @workspace,
      resolver: fake_resolver do
        resolver_result("I prepared one proposal for review. Nothing has been saved.", [
          operation("identity.assistant_name", "Lina", evidence: "Lina")
        ])
      end
    ).call(user_message: "Call the assistant Lina.", idempotency_key: "after-unexpected-failure")

    assert_equal "ready", fresh.turn.status
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
      "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Håfa adai. A reviewed welcome greeting.",
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
    ).call(user_message: "Use the exact phrase Håfa adai. A reviewed welcome greeting.", idempotency_key: "role-capture-turn")
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

  test "Claude persona setup payload asks for schema-shaped JSON because Anthropic cannot compile the strict grammar" do
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "anthropic/claude-sonnet-5.5", transport: Object.new)
    payload = resolver.payload_for(context: { "authoring_state" => {} }, user_message: "Draft a philosophy")

    assert_equal({ type: "json_object" }, payload.fetch(:response_format))
    refute payload.key?(:temperature)
    assert_equal({ require_parameters: true, allow_fallbacks: false, data_collection: "deny" }, payload.fetch(:provider))
    assert_includes payload.fetch(:messages).last.fetch(:content), resolver.send(:response_schema).to_json
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
      paths = schema.dig(:properties, "path", :enum)
      if paths.intersect?(%w[culture.local_realities culture.references])
        assert_empty paths & Mia::PersonaSetup::OperationContract::TRANSCRIPT_DRAFTABLE_PATHS
        assert_equal [ "coach_quote" ], schema.dig(:properties, "source_basis", :enum)
      end
      derived = schema.dig(:properties, "op", :const) == "set" && (paths & Mia::PersonaSetup::OperationContract::TRANSCRIPT_DRAFTABLE_PATHS).any?
      assert_equal derived ? %w[coach_quote mia_drafted] : [ "coach_quote" ], schema.dig(:properties, "source_basis", :enum)
    end
    prompt = payload.fetch(:messages).pluck(:content).join(" ")
    assert_includes prompt, "proposal or review wording"
    assert_includes prompt, "2–3 short, plain sentences"
    assert_includes prompt, "nothing has been saved"
    assert_includes prompt, "changed, set, added, saved, applied, created, or completed"
  end

  test "setup replies replace long technical explanations with a short invitation to review" do
    [ "The allowed options are approximations of your wording.", "A long recap. " * 60 ].each do |message|
      response = provider_response(model: "exact/model", content: JSON.generate("assistant_message" => message, "operations" => [ { "op" => "set" } ]))
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })
      reply = resolver.call(context: {}, user_message: "Propose my voice.").assistant_message
      assert_includes reply, "suggestions for your assistant."
      refute_includes reply, "assistant’s voice"
      assert_includes reply, "Nothing has been saved."
      assert_includes reply, "Change anything"
      assert_operator reply.length, :<, 200
      refute_match(/allowed options|approximations|applied/i, reply)
    end
  end

  test "provider transport refuses plaintext endpoints before creating an authorization request" do
    http = Object.new
    http.define_singleton_method(:start) { |*| raise "plaintext provider transport must not start" }
    transport = Mia::PersonaSetup::ProposalResolver::NetHttpTransport.new(
      api_key: "secret",
      endpoint: -> { URI("http://127.0.0.1:4567/chat") },
      http:
    )

    error = assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { transport.call("private" => true) }
    assert_equal "persona_setup_unavailable", error.code
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

    with_mia_provider_capacity_rejected do |call_sites|
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { flunk "transport must not run" })
      assert_equal "persona_setup_busy", assert_raises(Mia::PersonaSetup::ProposalResolver::Error) { resolver.call(context: {}, user_message: "Hello") }.code
      assert_equal [ "persona_setup" ], call_sites
    end
  end

  test "provider replaces completion claims with truthful review wording without trusting the narrative" do
    operations = [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]
    [
      "I've published the persona.",
      "I assigned the assistant to the cohort.",
      "The changes have been applied.",
      "No changes have been applied.",
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
      "I updated the name.",
      "I updated it for you.",
      "I changed that for you.",
      "It has been saved.",
      "I renamed it Lina.",
      "I added Håfa adai.",
      "We successfully modified that.",
      "This was already applied.",
      "The name has been updated.",
      "I set it to Lina.",
      "I’ve changed it.",
      "I changed my mind about the order. I updated it for you.",
      "Håfa adai has been added.",
      "Lina is now configured.",
      "Lina is ready to use.",
      "Those changes were applied.",
      "All changes are saved.",
      "Everything has been updated.",
      "It’s been saved.",
      "Name set to Lina.",
      "The update is complete.",
      "Nothing has been saved, but I applied the changes.",
      "No changes have been applied; Lina is now configured.",
      "I changed my mind; I updated it for you.",
      "This explanation is complete, and the persona is now live.",
      "The assistant’s name is now Lina.",
      "The name now reads Lina.",
      "Lina is good to go.",
      "Håfa adai is in the persona now.",
      "Nothing has been saved but I applied the changes.",
      "Nothing has been saved — I applied the changes.",
      "Nothing has been saved – I applied the changes.",
      "Nothing has been saved and I applied the changes.",
      "The proposal has been updated for review but the persona is now live.",
      "This explanation is complete but the persona is now live.",
      "This explanation is complete so the persona is now live.",
      "I changed my mind but I updated it for you.",
      "I changed my mind yet I updated it for you.",
      "I updated the proposal for review but I applied the changes.",
      "I revised the draft for review — Lina is now configured.",
      "The assistant name is pending review but Lina is now configured.",
      "Removed the phrase.",
      "Your setup is complete.",
      "All set."
    ].each do |message|
      response = provider_response(
        model: "exact/model",
        content: JSON.generate("assistant_message" => message, "operations" => operations)
      )
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

      result = resolver.call(context: {}, user_message: "Call the assistant Lina.")
      assert_includes result.assistant_message, "Nothing has been saved.", message
      refute_equal message, result.assistant_message
      assert_equal operations, result.operations
    end

    [
      "I prepared one draft change for review. Nothing has been saved.",
      "Your persona draft is ready for review. Apply it only if it looks right.",
      "I changed my mind about the order of these questions.",
      "I changed the tone of this explanation to make it clearer.",
      "I added context below to explain this proposal.",
      "I edited this explanation for clarity.",
      "I can update that after you approve the proposal.",
      "I will propose a name change for review.",
      "It will be saved only after you apply the proposal.",
      "It has not been saved.",
      "That change is proposed for review.",
      "Håfa adai will be added only after you apply the proposal.",
      "Lina is proposed as the assistant name for review.",
      "Nothing has been added.",
      "Nothing’s been saved.",
      "No changes have been saved.",
      "The proposal has been updated for review. Nothing has been saved.",
      "The draft is complete and ready for review.",
      "This explanation is complete.",
      "This explanation was made clearer for the review.",
      "This explanation is ready to use as a review guide.",
      "This explanation is good to go.",
      "The assistant name will be Lina only after you apply the proposal.",
      "The assistant name is not Lina until you apply the proposal.",
      "The assistant name is under review.",
      "The assistant name is proposed as Lina for review.",
      "The assistant name is now under review.",
      "The assistant name is now proposed as Lina for review.",
      "The assistant name is now not Lina until approval.",
      "The assistant name is pending review.",
      "The assistant name is still under review.",
      "Håfa adai would be added to the persona after approval.",
      "I prepared tone, language style, and accountability changes for review. Nothing has been saved.",
      "I prepared voice and language style changes for review. Nothing has been saved.",
      "I updated the proposal for review. Nothing has been saved.",
      "I revised the draft for review. Nothing has been saved.",
      "I prepared an updated name for review. Nothing has been saved.",
      "I'm proposing that change for review. Nothing has been saved."
    ].each do |message|
      response = provider_response(
        model: "exact/model",
        content: JSON.generate("assistant_message" => message, "operations" => operations)
      )
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

      assert_equal message, resolver.call(context: {}, user_message: "Call the assistant Lina.").assistant_message
    end
  end

  test "a fresh descriptive voice request produces a reviewed proposal despite a name recap" do
    message = "Her name is Mia, Mrs. Mel’s digital coaching assistant. Use a warm, direct tone and ask one practical question at a time. The participant is the household CFO."
    operations = [ operation("identity.assistant_name", "Mia", evidence: "Mia"),
      operation("coaching.do", [ "ask one practical question at a time" ], evidence: "ask one practical question at a time") ]
    response = provider_response(model: "exact/model", content: JSON.generate(
      "assistant_message" => "The assistant name is Mia. Here are proposed changes for review. Nothing has been saved.",
      "operations" => operations))
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })
    before = @persona.draft_config.deep_dup
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver: resolver)
      .call(user_message: message, idempotency_key: "descriptive-first-request")
    assert_equal "ready", result.turn.status
    assert_equal "pending", result.proposal.status
    assert_includes result.turn.assistant_message, "Nothing has been saved."
    assert_equal before, @persona.reload.draft_config
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

  [
    [ "All set.", "Nothing has been saved. Tell me what you would like to change, and I will propose it for you to review." ],
    [ "Which part of Mia's voice would you like to change?", "Which part of Mia's voice would you like to change?" ]
  ].each do |provider_message, expected_message|
    test "full turn preserves clarification and metadata without a proposal for #{provider_message}" do
      response = provider_response(model: "exact/model", content: JSON.generate("assistant_message" => provider_message, "operations" => []))
      resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })
      original_revision = @persona.draft_revision
      original_config = @persona.draft_config.deep_dup
      original_activity = 1.hour.ago
      @session.update!(last_activity_at: original_activity)
      runner = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)

      result = nil
      assert_no_difference "CoachPersonaSetupProposal.count" do
        result = runner.call(user_message: "Make Mia warmer.", idempotency_key: "clarification-key-123")
      end
      turn = result.turn.reload
      assert_equal "ready", turn.status
      assert_equal expected_message, turn.assistant_message
      assert_nil result.proposal
      assert_nil turn.proposal
      assert_nil turn.error_code
      assert_equal "test", turn.provider
      assert_equal "exact/model", turn.model
      assert_equal Mia::PersonaSetup::ProposalBuilder::PROMPT_VERSION, turn.prompt_version
      assert_equal Mia::PersonaSetup::ProposalBuilder::SCHEMA_VERSION, turn.schema_version
      assert_equal({ "total_tokens" => 10 }, turn.usage)
      assert_operator @session.reload.last_activity_at, :>, original_activity
      assert_equal original_revision, @persona.reload.draft_revision
      assert_equal original_config, @persona.draft_config
      replay = runner.call(user_message: "Make Mia warmer.", idempotency_key: "clarification-key-123")
      assert replay.replayed
      assert_equal turn.id, replay.turn.id
      assert_nil replay.proposal
    end
  end

  test "fresh QA continues a sealed prior prompt proposal without trusting a changed seal" do
    previous = ready_proposal(name: "Lina")
    legacy = CoachPersonaSetupProposal.new(previous.attributes.except("id", "created_at", "updated_at"))
    legacy.prompt_version = "coach_persona_setup_v4"
    legacy.proposal_digest = Mia::PersonaSetup::ProposalBuilder.digest_for(persona: @persona,
      base_draft_revision: legacy.base_draft_revision, base_config_digest: legacy.base_config_digest,
      operations: legacy.operations, before_state: legacy.before_state, after_state: legacy.after_state,
      prompt_version: legacy.prompt_version)
    error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::ProposalBuilder.new(persona: @persona, actor: @coach,
        user_message: "Use 4 sentences.", previous: legacy).call([ operation("response_shape.max_sentences", 4, evidence: "4 sentences") ], partial: true)
    end
    assert_equal "persona_setup_stale_proposal", error.code
    assert_includes error.public_message, "Reject this proposal"
    legacy.operations = [ operation("identity.assistant_name", "Forged", evidence: "Forged") ]
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::ProposalBuilder.new(persona: @persona, actor: @coach,
        user_message: "Use 4 sentences.", previous: legacy).call([
          operation("response_shape.max_sentences", 4, evidence: "4 sentences")
        ], partial: true)
    end
  end

  test "fresh QA literal phrase recovery respects negation and the crisis boundary" do
    [ 'Do not say "Chelu".', 'She never says "Chelu".', 'Remove the phrase "Chelu".',
      'Her phrase is not "Chelu".', 'Her phrase isn’t "Chelu".', 'She no longer says "Chelu".' ].each do |message|
      assert_empty Mia::PersonaSetup::PhraseSuggestions.new(message:).call([])
    end
    literal = Mia::PersonaSetup::PhraseSuggestions.new(message: 'She says "Never give up.".').call([])
    assert_empty literal # A message alone must never create a phrase operation.
    operation = { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => "Chelu",
      "value" => { "text" => "Chelu", "meaning" => "Invented meaning", "allowed_contexts" => [ "crisis" ],
        "prohibited_contexts" => [], "frequency" => "rare", "caution" => "" } }
    assert_equal [ operation ], Mia::PersonaSetup::PhraseSuggestions.new(message: 'Say "Chelu".').call([ operation ])
  end

  test "fresh QA followups accumulate suggestions in the same list" do
    runner = ->(message, operations, key) do
      Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
        resolver: fake_resolver { resolver_result("Review this.", operations) }).call(user_message: message, idempotency_key: key).proposal
    end
    runner.call("Celebrate small wins.", [ operation("coaching.do", [ "Celebrate small wins." ], evidence: "Celebrate small wins.") ], "fresh-qa-list-one")
    proposal = runner.call("Ask one practical question.", [ operation("coaching.do", [ "Ask one practical question." ], evidence: "Ask one practical question.") ], "fresh-qa-list-two")
    assert_equal [ "Celebrate small wins.", "Ask one practical question." ], proposal.after_state.dig("draft_config", "coaching", "do")
    replacement = runner.call("Remove Celebrate small wins.", [ operation("coaching.do", [ "Ask one practical question." ], evidence: "Remove Celebrate small wins.") ], "fresh-qa-list-remove")
    assert_equal [ "Ask one practical question." ], replacement.after_state.dig("draft_config", "coaching", "do")
  end

  test "fresh QA real provider response keeps celebration method traits and exact phrase" do
    fixture = JSON.parse(file_fixture("persona_setup/fresh_qa_voice_response.json").read)
    message = 'Her voice is like a Guam auntie: warm; direct; respectful; encouraging. Keep answers to 3 or 4 sentences. Never shame anyone. She celebrates small wins. She always gives the direct answer first, and then asks one practical question. She says "Chelu, pump the brakes."'
    result = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result(fixture.fetch("assistant_message"), fixture.fetch("operations")) })
      .call(user_message: message, idempotency_key: "fresh-qa-real-response")
    config = result.proposal.after_state.fetch("draft_config")
    assert_equal "Chelu, pump the brakes.", config.fetch("phrases").sole.fetch("text")
    assert_includes config.dig("coaching", "do"), "Celebrate small wins."
    assert_equal "Give the direct answer first, and then ask one practical question.", config.dig("coaching", "method")
    assert_equal %w[warm direct respectful encouraging], config.dig("voice", "tone_traits")
    refute_includes result.turn.assistant_message, "Left out:"
  end

  test "fresh QA quoted phrase remains reviewable without an invented interpretation" do
    phrase = "Chelu, pump the brakes."
    message = %(Please add her saying, word for word: "#{phrase}")
    raw = { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => phrase,
      "value" => { "text" => phrase, "meaning" => "A phrase the coach always says to stop overspending.",
        "allowed_contexts" => [ "general" ], "prohibited_contexts" => [ "crisis" ], "frequency" => "as_needed", "caution" => "" } }
    result = with_proposal_guard(allowed: false) do
      Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
        resolver: fake_resolver { resolver_result("Review this. Nothing has been saved.", [ raw ]) })
        .call(user_message: message, idempotency_key: "fresh-qa-phrase")
    end
    assert_nil result.proposal
    assert_includes result.turn.assistant_message, "Left out:"
    assert_empty @persona.reload.draft_config.fetch("phrases")
  end

  test "fresh QA followups retain and save every earlier suggestion across reloads" do
    first = ready_proposal(name: "Lina")
    second = Mia::PersonaSetup::TurnRunner.new(session: @session.reload, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this.", [ operation("coaching.do_not", [ "Never shame anyone." ], evidence: "Never shame anyone.") ]) })
      .call(user_message: "Never shame anyone.", idempotency_key: "fresh-qa-followup").proposal
    assert_equal "superseded", first.reload.status
    assert_equal %w[identity.assistant_name coaching.do_not], second.operations.map { |op| op.fetch("path") }
    third = Mia::PersonaSetup::TurnRunner.new(session: @session.reload, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this.", [ operation("response_shape.max_sentences", 4, evidence: "4 sentences") ]) })
      .call(user_message: "Use 4 sentences.", idempotency_key: "fresh-qa-followup2").proposal
    applied = Mia::PersonaSetup::ProposalApplier.new(proposal: third, actor: @coach, workspace: @workspace).apply!(idempotency_key: "fresh-qa-save-all")
    assert_equal "Lina", applied.draft_config.dig("identity", "assistant_name")
    assert_equal [ "Never shame anyone." ], applied.draft_config.dig("coaching", "do_not")
    assert_equal 4, applied.draft_config.dig("response_shape", "max_sentences")
  end

  test "fresh QA pending voice choices survive additions but never authorize new unsupported claims" do
    first = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this.", [ operation("voice.tone_traits", %w[warm direct respectful practical], evidence: "practical") ]) })
      .call(user_message: "Be practical.", idempotency_key: "fresh-qa-practical").proposal
    second = Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
      resolver: fake_resolver { resolver_result("Review this.", [ operation("voice.tone_traits", %w[warm direct respectful practical concise], evidence: "brief") ]) })
      .call(user_message: "Keep it brief.", idempotency_key: "fresh-qa-brief").proposal
    assert_equal %w[warm direct respectful practical concise], second.after_state.dig("draft_config", "voice", "tone_traits")
    result = with_proposal_guard(allowed: false) do
      Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace,
        resolver: fake_resolver { resolver_result("Review this.", [ operation("voice.tone_traits", %w[warm direct respectful practical concise formal], evidence: "practical") ]) })
        .call(user_message: "Keep it brief.", idempotency_key: "fresh-qa-no-laundering")
    end
    assert_nil result.proposal
    assert_equal "ready", result.turn.status
    assert_includes result.turn.assistant_message, "Left out:"
    assert_equal "pending", second.reload.status
    assert_equal "superseded", first.reload.status
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

  test "a completion claim with no proposed operations never says there is something to review" do
    response = provider_response(model: "exact/model", content: JSON.generate("assistant_message" => "All set.", "operations" => []))
    resolver = Mia::PersonaSetup::ProposalResolver.new(api_key: "test", model: "exact/model", transport: ->(_) { response })

    # This checks response wording. Admission denial is covered separately;
    # the database semaphore's one-second deadline is unrelated to this contract.
    original = HouseholdFinance::MiaProviderAdmission.method(:with_slot)
    HouseholdFinance::MiaProviderAdmission.define_singleton_method(:with_slot) { |**_options, &provider_call| provider_call.call }
    result = resolver.call(context: {}, user_message: "Make Mia warmer.")
    assert_equal [], result.operations
    assert_includes result.assistant_message, "Nothing has been saved."
    refute_includes result.assistant_message, "Review these proposed draft changes"
  ensure
    HouseholdFinance::MiaProviderAdmission.define_singleton_method(:with_slot, original) if original
  end
end
