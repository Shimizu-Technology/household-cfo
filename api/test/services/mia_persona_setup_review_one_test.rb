require "test_helper"
require_relative "../support/proposal_guard_test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupReviewOneTest < ActiveSupport::TestCase
  include ProposalGuardTestHelper
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

  [ "Client 1", "Participant #2", "Speaker 3", "Unknown speaker with a long label", "A1", "Client (guest)", "Client [1]", "Guest / visitor", "Guest 🤷", "Client phrases" ].each do |speaker|
    test "review two rejects noncoach transcript speaker #{speaker}" do
      message = %(#{speaker}: I say "Chelu")
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message, coach_name: "Mrs. Mel").exact_quote("Chelu")
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase("Chelu") ]) }
    end
  end

  [ "Client 1", "Participant #2", "Speaker 3", "Note: Client 1", "Guest / visitor", '"Client 1"' ].each do |speaker|
    test "review followup rejects nested #{speaker} inside a coach line" do
      message = %(Coach: #{speaker}: I say "Chelu")
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Chelu")
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase("Chelu") ]) }
    end
  end

  [ "but do not use that phrase", "but don't add that phrase", "but never use that phrase" ].each do |refusal|
    test "review followup rejects quoted wording followed by #{refusal}" do
      message = %(She says "Chelu" #{refusal})
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Chelu")
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase("Chelu") ]) }
    end
  end

  test "review followup unquoted authoring also respects a later refusal" do
    message = "Use the exact phrase Chelu but do not use that phrase"
    assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Chelu")
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase("Chelu") ]) }
  end

  test "review followup keeps a coach note as prose rather than a client label" do
    message = %(Coach: Note: I say "Chelu")
    assert_equal "Chelu", Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Chelu")
    assert_equal "Chelu", contract(message).build([ phrase("Chelu") ]).dig(:after_state, "draft_config", "phrases").sole["text"]
  end

  test "review followup preserves a colon inside a direct coach quote" do
    message = %(Coach: "Pause: name your choice.")
    assert_equal "Pause: name your choice.", Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Pause: name your choice.")
    assert_equal "Pause: name your choice.", contract(message).build([ phrase("Pause: name your choice.") ]).dig(:after_state, "draft_config", "phrases").sole["text"]
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
    assert_equal proposed["value"]["meaning"], actual["meaning"]
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
    assert_nil run_turn('She says "Chelu, pump the brakes.".', [ phrase("Chelu, pump the brakes.") ]).proposal
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

  [ "Kill yourself", "You are a failure" ].each do |text|
    test "R17 harmful phrase #{text} fails setup and direct draft authoring" do
      message = %(She says "#{text}")
      result = run_turn(message, [ phrase(text) ])
      assert_equal "ready", result.turn.status
      assert_nil result.proposal
      assert_includes result.turn.assistant_message, "Left out:"
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

  test "CR4 malformed phrase siblings are left out without losing a valid name" do
    result = contract("Call the assistant Lani").build_partial([ op("identity.assistant_name", "Lani", "Lani"), phrase.merge("value" => { "meaning" => "Missing text" }) ])
    assert_equal "Lani", result.dig(:after_state, "draft_config", "identity", "assistant_name")
    assert_equal 1, result[:dropped].length
  end

  test "CR5 malformed list items do not crash partial salvage or become coerced arrays" do
    [ 123, [ "Nested" ] ].each do |invalid|
      result = contract("Call the assistant Lani").build_partial([ op("identity.assistant_name", "Lani", "Lani"), op("coaching.do_not", [ invalid ], "Lani") ])
      assert_equal "Lani", result.dig(:after_state, "draft_config", "identity", "assistant_name")
      assert_equal 1, result[:dropped].length
    end
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract("Ask one question").build([ op("coaching.do", "Ask one question", "Ask one question") ]) }
  end

  [ 'Her mom says "Chelu"', 'Her auntie says "Chelu"', 'Her sister says "Chelu"', 'I heard my neighbor say "Chelu"' ].each do |message|
    test "CR6 direct coach subject required #{message}" do
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ phrase("Chelu") ]) }
    end
  end

  test "CR7 a previous prohibition does not ban a later explicit unquoted phrase command" do
    result = run_turn("Never shame anyone. She celebrates small wins. Use the exact phrase Håfa adai.", [ phrase("Håfa adai") ])
    assert_equal "Håfa adai", result.proposal.after_state.dig("draft_config", "phrases").sole["text"]
  end

  test "CR3 legacy crisis context stays readable but cannot be introduced by a new edit" do
    legacy = persona_phrase_artifact({}, source_user_id: @coach.id)
    legacy["allowed_contexts"] = [ "crisis" ]; legacy["prohibited_contexts"] = []
    legacy["fingerprint"] = Mia::PersonaSchema.artifact_fingerprint(legacy)
    config = @persona.draft_config.deep_merge("phrases" => [ legacy ])
    @persona.update_columns(draft_config: config)
    assert Mia::PersonaSchema.digest(@persona.reload.draft_config)
    assert_equal [ legacy ], Mia::PersonaSchema.prepare_draft_artifacts(config, source_user_id: @coach.id, existing_configuration: config)["phrases"]
    changed = config.deep_dup; changed["phrases"][0]["meaning"] = "Changed meaning"
    assert_raises(Mia::PersonaSchema::InvalidConfiguration) { Mia::PersonaSchema.prepare_draft_artifacts(changed, source_user_id: @coach.id, existing_configuration: config) }
  end

  test "CR18 another coaches pending suggestions require atomic confirmation before manual save" do
    run_turn("Call the assistant Lani", [ op("identity.assistant_name", "Lani", "Lani") ])
    other = persona_user; @workspace.coach_workspace_memberships.create!(user: other, role: "editor")
    config = @persona.draft_config.deep_dup; config["coaching"]["method"] = "Ask one question."
    args = { expected_draft_revision: @persona.draft_revision, description: @persona.description, draft_config: config }
    error = assert_raises(Mia::PersonaDraftUpdater::Error) { Mia::PersonaDraftUpdater.new(persona: @persona, actor: other, workspace: @workspace, protect_pending_suggestions: true).call!(**args) }
    assert_equal "persona_pending_suggestions", error.code
    assert_equal "pending", @session.proposals.sole.status
    Mia::PersonaDraftUpdater.new(persona: @persona, actor: other, workspace: @workspace, protect_pending_suggestions: true, discard_pending_suggestions: true).call!(**args)
    assert_equal "stale", @session.proposals.sole.status
    assert_equal "Ask one question.", @persona.reload.draft_config.dig("coaching", "method")
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
