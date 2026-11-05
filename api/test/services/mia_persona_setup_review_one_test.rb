require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupReviewOneTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace)
    @session = CoachPersonaSetupSession.create!(coach_persona: @persona, coach_workspace: @workspace,
      created_by_user: @coach, base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config), last_activity_at: Time.current)
  end

  [ "Stop saying", "Dont say", "Avoid saying", "She refuses to say", "Instead of saying", "Rather than saying",
    "Without saying", "Delete the phrase", "Take out the phrase", "Ban the phrase", "Get rid of the phrase",
    "I hate the phrase", "Donʼt say" ].each do |prefix|
    test "R1 banned quote is never injected for #{prefix}" do
      message = %(#{prefix} "Chelu, pump the brakes". It sounds rude.)
      result = run_turn(message, [])
      assert_nil result.proposal
      assert_empty @session.proposals
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase ]) }
    end
  end

  [ 'My client says "I am a failure"', 'Maria says "My husband hits me"', 'Her mother used to say "Chelu"',
    'Client: my friend says "I can\'t pay 0"' ].each do |message|
    test "R2 other speakers cannot become coach phrases #{message}" do
      assert_nil run_turn(message, []).proposal
      text = message[/"([^"]+)"/, 1]
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase(text) ]) }
    end
  end

  test "R2 thirty transcript quotes do not fail a valid name change" do
    message = "Call the assistant Lani.\n" + 30.times.map { |i| %(Client: my friend says "I can't pay #{i}") }.join("\n")
    result = run_turn(message, [ op("identity.assistant_name", "Lani", "Lani") ])
    assert_equal "ready", result.turn.status
    assert_empty result.proposal.after_state.dig("draft_config", "phrases")
  end

  test "R1 M1 model phrase exact quote is accepted trailing punctuation aside without inventing meaning" do
    message = 'Please add her saying, word for word: "Chelu, pump the brakes."'
    proposed = phrase("Chelu, pump the brakes")
    proposed["value"]["meaning"] = "A phrase to stop overspending."
    result = run_turn(message, [ proposed ])
    actual = result.proposal.after_state.dig("draft_config", "phrases").sole
    assert_equal "Chelu, pump the brakes.", actual["text"]
    assert_equal actual["text"], actual["meaning"]
    assert_nil run_turn('She says "Another phrase".', []).proposal
  end

  test "R2 coach speaker lines authorize only the coach not nested client speech" do
    message = "Propose a voice from this transcript:\nClient: I say \"Client phrase\"\nCoach: I say \"Coach phrase\""
    result = run_turn(message, [ phrase("Coach phrase"), phrase("Client phrase") ])
    assert_equal [ "Coach phrase" ], result.proposal.after_state.dig("draft_config", "phrases").map { |item| item["text"] }
    assert_includes result.turn.assistant_message, "Left out:"
  end

  [ "Actually take out the one about small wins", "Remove celebrate small wins." ].each do |message|
    test "R3 explicit removal #{message}" do
      prior = [ op("coaching.do", [ "Celebrate small wins", "Ask one question" ], "Celebrate small wins and ask one question") ]
      result = contract(message, prior).build_partial([ op("coaching.do", [ "Ask one question" ], message) ])
      assert_equal [ "Ask one question" ], result.dig(:after_state, "draft_config", "coaching", "do")
    end
  end

  test "R3 do not remove keeps the item and a prohibition drops contradictory guidance" do
    prior = [ op("coaching.do", [ "Celebrate small wins" ], "Celebrate small wins") ]
    result = contract("Do not remove Celebrate small wins.", prior).build_partial([ op("coaching.do", [], "Do not remove Celebrate small wins.") ])
    assert_equal [ "Celebrate small wins" ], result.dig(:after_state, "draft_config", "coaching", "do")
    result = contract("Actually never celebrate small wins", prior).build_partial([ op("coaching.do_not", [ "Never celebrate small wins" ], "never celebrate small wins") ])
    assert_empty result.dig(:after_state, "draft_config", "coaching", "do")
    assert_equal [ "Never celebrate small wins" ], result.dig(:after_state, "draft_config", "coaching", "do_not")
  end

  test "R3 each sealed list line can be saved independently and retries preserve selection" do
    result = run_turn("Celebrate small wins and ask one question", [ op("coaching.do", [ "Celebrate small wins", "Ask one question" ], "Celebrate small wins and ask one question") ])
    applier = Mia::PersonaSetup::ProposalApplier.new(proposal: result.proposal, actor: @coach, workspace: @workspace)
    args = { idempotency_key: "list-choice-apply", accepted_operation_indexes: [ 0 ], accepted_list_item_indexes: { "0" => [ 1 ] } }
    saved = applier.apply!(**args)
    assert_equal [ "Ask one question" ], saved.draft_config.dig("coaching", "do")
    assert_equal saved, applier.apply!(**args)
    assert_raises(Mia::PersonaSetup::ProposalApplier::Error) { applier.apply!(**args.merge(accepted_list_item_indexes: { "0" => [ 0 ] })) }
  end

  test "R10 repeated punctuation variants never duplicate pending or saved phrases" do
    first = run_turn('She says "Chelu, pump the brakes".', [ phrase ]).proposal
    second = run_turn('Please add her saying, word for word: "Chelu, pump the brakes."', [ phrase("Chelu, pump the brakes.") ]).proposal
    assert_equal 1, second.after_state.dig("draft_config", "phrases").length
    assert_equal "superseded", first.reload.status
    Mia::PersonaSetup::ProposalApplier.new(proposal: second, actor: @coach, workspace: @workspace).apply!(idempotency_key: "save-first-phrase")
    assert_raises(Mia::PersonaSetup::TurnRunner::Error) { run_turn('She says "Chelu, pump the brakes.".', [ phrase("Chelu, pump the brakes.") ]) }
    assert_equal 1, @persona.reload.draft_config["phrases"].length
  end

  test "R11 removing pending phrase and returning pending name to saved value cancel them" do
    run_turn('Call the assistant Lani. She says "Chelu, pump the brakes".', [ op("identity.assistant_name", "Lani", "Lani"), phrase ])
    original = @persona.draft_config.dig("identity", "assistant_name")
    result = run_turn("Remove Chelu, pump the brakes. Call the assistant #{original}.", [ op("identity.assistant_name", original, original), phrase.merge("op" => "remove_phrase", "value" => "Chelu, pump the brakes") ])
    assert_equal "ready", result.turn.status
    assert_nil result.proposal
    assert_empty @session.proposals.where(status: "pending")
    assert_equal original, @persona.reload.draft_config.dig("identity", "assistant_name")
  end

  [ "She rarely celebrates small wins", "She stopped celebrating small wins", "She avoids celebrating small wins",
    "She refuses to celebrate small wins", "She used to celebrate small wins" ].each do |source|
    test "R7 R8 limiting polarity #{source}" do
      refute Mia::PersonaSetup::TextEvidence.supports?(source, "Celebrate small wins")
    end
  end
  [ "Do not ever shame anyone", "Don't ever shame anyone", "Never ever shame anyone", "She doesnt shame clients",
    "Nobody should shame clients", "She wouldnt shame clients", "She shouldnt shame clients", "She isnt shaming clients", "She hasn't shamed clients" ].each do |source|
    test "R8 negative polarity #{source}" do
      refute Mia::PersonaSetup::TextEvidence.supports?(source, "Shame clients"), source
    end
  end
  test "R8 negative cue before ask cannot become positive" do
    refute Mia::PersonaSetup::TextEvidence.supports?("She didnt ask questions", "Ask questions")
    assert Mia::PersonaSetup::TextEvidence.supports?("Do not ever shame clients", "Never shame clients")
  end

  [ "Kill yourself", "You are a failure" ].each do |text|
    test "R17 harmful phrase #{text} fails setup and direct draft authoring" do
      message = %(She says "#{text}")
      assert_raises(Mia::PersonaSetup::TurnRunner::Error) { run_turn(message, [ phrase(text) ]) }
      config = @persona.draft_config.deep_dup
      config["phrases"] = [ phrase(text)["value"] ]
      assert_raises(Mia::PersonaDraftUpdater::Error) do
        Mia::PersonaDraftUpdater.new(persona: @persona, actor: @coach, workspace: @workspace).call!(expected_draft_revision: @persona.draft_revision, description: @persona.description, draft_config: config)
      end
    end
  end
  test "R17 direct draft cannot permit phrases in crisis" do
    config = @persona.draft_config.deep_dup
    config["phrases"] = [ phrase["value"].merge("allowed_contexts" => [ "crisis" ]) ]
    assert_raises(Mia::PersonaDraftUpdater::Error) do
      Mia::PersonaDraftUpdater.new(persona: @persona, actor: @coach, workspace: @workspace).call!(expected_draft_revision: @persona.draft_revision, description: @persona.description, draft_config: config)
    end
  end

  test "R8 ordinary words ending in nt do not become negations" do
    assert Mia::PersonaSetup::TextEvidence.supports?("I want to celebrate small wins", "Celebrate small wins")
    assert Mia::PersonaSetup::TextEvidence.supports?("Count the amount for rent", "Count the amount for rent")
    refute Mia::PersonaSetup::TextEvidence.supports?("She hadnt asked questions", "Ask questions")
  end

  private
  def contract(message, prior = [])
    evidence_state = @persona.draft_config.deep_dup
    prior.select { |operation| operation["op"] == "set" }.each do |operation|
      keys = operation["path"].split(".")
      keys[0...-1].reduce(evidence_state) { |value, key| value[key] }[keys.last] = operation["value"]
    end
    Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message, previous_operations: prior, evidence_state: evidence_state)
  end
  def op(path, value, evidence)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "coach_quote", "evidence_quote" => evidence }
  end
  def phrase(text = "Chelu, pump the brakes")
    { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => text,
      "value" => { "text" => text, "meaning" => text, "allowed_contexts" => [ "general" ], "prohibited_contexts" => [ "crisis" ], "frequency" => "rare", "caution" => "" } }
  end
  def run_turn(message, operations)
    resolver = Object.new
    resolver.define_singleton_method(:call) do |**|
      Mia::PersonaSetup::ProposalResolver::Result.new(assistant_message: "Review these suggestions. Nothing has been saved.", operations: operations,
        metadata: { "provider" => "test", "model" => "fixture", "prompt_version" => Mia::PersonaSetup::ProposalBuilder::PROMPT_VERSION, "schema_version" => Mia::PersonaSetup::ProposalBuilder::SCHEMA_VERSION })
    end
    Mia::PersonaSetup::TurnRunner.new(session: @session.reload, actor: @coach, workspace: @workspace, resolver: resolver).call(user_message: message, idempotency_key: SecureRandom.uuid)
  end
end
