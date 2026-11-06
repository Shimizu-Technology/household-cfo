# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupRiskSplitTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace)
    @session = CoachPersonaSetupSession.create!(coach_persona: @persona, coach_workspace: @workspace,
      created_by_user: @coach, base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config), last_activity_at: Time.current)
  end

  test "finite presets accept semantic mappings without positive synonym requirements" do
    [ "I’m reassuring without being sugary.", "My voice is gentle and down-to-earth.",
      "I want to be candid about tradeoffs without sounding harsh.", "I sound like a thoughtful teacher—clear explanations, room for questions, and no lecturing." ].each do |message|
      result = contract(message).build([ op("voice.tone_traits", %w[warm direct respectful reassuring candid], message) ])
      assert_includes result.dig(:after_state, "draft_config", "voice", "tone_traits"), "reassuring", message
    end
    message = "I leave room for questions and let the answer breathe."
    result = contract(message).build([ op("voice.energy", "Quiet and unhurried.", message),
      op("voice.accountability_style", "Ask reflective questions before naming a pattern.", message),
      op("voice.language_style", @persona.draft_config.dig("voice", "language_style") + [ "Prefer conversational language." ], message) ])
    assert_equal 3, result[:operations].length
  end

  test "preset contradictions use the complete message even when evidence cherry picks" do
    [ [ "My voice is gentle. No humour.", "My voice is gentle.", "lighthearted" ],
      [ "I am kind, never formal or lighthearted.", "I am kind", "formal" ],
      [ "I use humour only for celebrations.", "I use humour", "lighthearted" ],
      [ "My voice is warm, not practical.", "My voice is warm", "practical" ],
      [ "I never make jokes about their situation.", "I never make jokes about their situation.", "lighthearted" ] ].each do |message, evidence, trait|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, message) do
        contract(message).build([ op("voice.tone_traits", %w[warm direct respectful] + [ trait ], evidence) ])
      end
    end
  end

  test "presets reject client and reported speech and ordinary nouns" do
    [ [ "Client: My voice is gentle and down-to-earth.", "My voice is gentle and down-to-earth." ],
      [ 'My client said "My voice is gentle and down-to-earth."', "My voice is gentle and down-to-earth." ],
      [ "Coach: Client: I am gentle and down-to-earth.", "I am gentle and down-to-earth." ],
      [ "Sound like a friend. Maria: My voice is gentle.", "My voice is gentle." ],
      [ "We cover direct deposit.", "direct deposit" ],
      [ "Use a warm tone. We cover short term loans.", "short term loans" ] ].each do |message, evidence|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, message) do
        contract(message).build([ op("voice.tone_traits", %w[warm direct respectful candid], evidence) ])
      end
    end
  end

  test "mechanical free text framing preserves contractions articles and content words" do
    message = "I’m the friend who listens before offering a practical next step."
    claim = "Be the friend who listens before offering a practical next step."
    result = contract(message).build([ op("coaching.do", [ claim ], message) ])
    assert_equal [ claim ], result.dig(:after_state, "draft_config", "coaching", "do")
    assert Mia::PersonaSetup::TextEvidence.supports?("My voice is gentle and down-to-earth.", "Keep your voice gentle and down-to-earth.")
    refute Mia::PersonaSetup::TextEvidence.supports?("My voice is not gentle.", "Keep your voice gentle.")
    [ [ "I’m not the friend who listens before offering a practical next step.", claim ],
      [ "I’m the friend who listens only when asked.", "Be the friend who listens." ],
      [ "I’m the friend who listens.", "Be the friend who listens and guarantees success." ],
      [ "Client: I’m the friend who listens.", "Be the friend who listens." ],
      [ 'My client said "I’m the friend who listens."', "Be the friend who listens." ] ].each do |source, value|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, source) do
        contract(source).build([ op("coaching.do", [ value ], source) ])
      end
    end
  end

  test "generic role comparisons pass without enumerating familiar roles" do
    [ "Sound like a thoughtful teacher.", "Sound like a warm auntie.", "Talk like an older cousin.",
      "Respond like a good friend.", "Speak like a careful librarian.", "Reply like a patient gardener.", "Sound like a teacher of mathematics." ].each do |message|
      assert_empty Mia::CulturalSafetyPolicy.violations(message, field: :style_instruction), message
      assert contract(message).build([ op("coaching.do", [ message ], message) ])
    end
  end

  test "identity roles and stereotypes cannot hide inside a generic role" do
    [ "Sound like a Chamorro auntie.", "Talk like a local.", "Sound like an islander.", "Sound like a Filipino mom.",
      "Sound like a Catholic teacher.", "Speak like a teacher from Guam.", "Talk like a friend with a British accent.",
      "Sound like a thoughtful teacher. Chamorros always waste money.",
      "Sound like a warm auntie who knows that Zorblax women are careless with money." ].each do |message|
      assert_predicate Mia::CulturalSafetyPolicy.violations(message, field: :style_instruction), :present?, message
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, message) do
        contract(message).build([ op("coaching.do", [ message ], message) ])
      end
    end
  end

  test "all rejected operations give a ready reply and preserve pending review" do
    original = run_turn("Call the assistant Lina.", [ op("identity.assistant_name", "Lina", "Lina") ]).proposal
    result = run_turn("My voice is gentle.", [ op("identity.human_coach_name", "Invented name", "My voice is gentle.") ])
    assert_equal "ready", result.turn.reload.status
    assert_nil result.proposal
    assert_includes result.turn.assistant_message, "Left out:"
    assert_includes result.turn.assistant_message, "Nothing has been saved"
    refute_match(/could not prepare|suggestions below|add or remove/, result.turn.assistant_message)
    assert_equal "pending", original.reload.status
    assert_equal "Mrs. Mel", @persona.reload.draft_config.dig("identity", "human_coach_name")
  end

  test "every operation contract error is a note and valid suggestions survive" do
    message = 'Call the assistant Lina. I say "Pause". No humour. Client: "Not mine".'
    unsafe = [ op("identity.human_coach_name", "Invented", "Lina"),
      op("voice.tone_traits", %w[warm direct respectful lighthearted], "No humour"),
      op("coaching.do", [ "Recommend specific stocks." ], "Recommend specific stocks."),
      phrase("Pause", "crisis", 'I say "Pause"'), phrase("Not mine", "general", "Not mine"),
      op("protected.setting", "unsafe", "Lina") ]
    unsafe.each do |operation|
      result = run_turn(message, [ operation ])
      assert_equal "ready", result.turn.status
      assert_nil result.proposal
      assert_includes result.turn.assistant_message, "Left out:"
    end
    result = run_turn(message, unsafe + [ op("identity.assistant_name", "Lina", "Lina") ])
    assert_equal 1, result.proposal.operations.length
    assert_equal "Lina", result.proposal.after_state.dig("draft_config", "identity", "assistant_name")
    assert_empty result.proposal.after_state.dig("draft_config", "phrases")
    assert_equal "Mia", @persona.reload.draft_config.dig("identity", "assistant_name")
  end

  test "saved phrase use changes require evidence even when meaning stays unchanged" do
    original = persona_phrase_artifact({ "text" => "Pause", "meaning" => "Take one step.", "caution" => "Use gently." }, source_user_id: @coach.id)
    @persona.update!(draft_config: @persona.draft_config.deep_merge("phrases" => [ original ]))
    message = 'I say "Pause".'
    [ { "frequency" => "as_needed" }, { "allowed_contexts" => [ "verified_milestone" ] },
      { "prohibited_contexts" => [ "crisis", "emotional_support" ] }, { "caution" => "Use for everyone." }, { "caution" => "" } ].each do |change|
      value = original.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution").merge(change)
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, change.inspect) do
        contract(message).build([ op("phrases", value, message).merge("op" => "add_phrase") ])
      end
    end
    value = original.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution").merge("frequency" => "as_needed")
    message = 'Please use my saying "Pause" often.'
    result = contract(message).build([ op("phrases", value, message).merge("op" => "add_phrase") ])
    saved = result.dig(:after_state, "draft_config", "phrases").sole
    assert_equal "as_needed", saved["frequency"]
    assert_equal original["allowed_contexts"], saved["allowed_contexts"]
    assert_equal original["caution"], saved["caution"]
  end

  test "saved phrase use cannot borrow client frequency or a negated caution removal" do
    original = persona_phrase_artifact({ "text" => "Pause", "meaning" => "Take one step.", "caution" => "Use gently." }, source_user_id: @coach.id)
    @persona.update!(draft_config: @persona.draft_config.deep_merge("phrases" => [ original ]))
    base = original.slice("text", "meaning", "allowed_contexts", "prohibited_contexts", "frequency", "caution")
    [ [ 'I say "Pause". Do not remove the caution.', "Do not remove the caution.", { "caution" => "" } ],
      [ "I say \"Pause\".\nClient: Use it often.", "Use it often.", { "frequency" => "as_needed" } ] ].each do |message, evidence, change|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, message) do
        contract(message).build([ op("phrases", base.merge(change), evidence).merge("op" => "add_phrase") ])
      end
    end
    message = 'I say "Pause". Remove the caution.'
    result = contract(message).build([ op("phrases", base.merge("caution" => ""), message).merge("op" => "add_phrase") ])
    assert_equal "", result.dig(:after_state, "draft_config", "phrases").sole["caution"]
  end

  test "the sixteen recorded first messages and followups retain their complete suggestions" do
    %w[voice_risk_split_replay voice_round_two_replay].flat_map { |name| JSON.parse(file_fixture("persona_setup/#{name}.json").read) }.each_slice(2) do |pair|
      pair.each do |recorded|
        result = run_turn(recorded.fetch("message"), recorded.fetch("operations"))
        assert_equal "ready", result.turn.status
        assert result.proposal, recorded.fetch("message")
        refute_includes result.turn.assistant_message, "Left out:", recorded.fetch("message")
      end
      @session.reload.update!(status: "abandoned")
      @session = CoachPersonaSetupSession.create!(coach_persona: @persona, coach_workspace: @workspace,
        created_by_user: @coach, base_draft_revision: @persona.draft_revision,
        base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config), last_activity_at: Time.current)
    end
  end

  test "fifteen safety replays reject unsupported operations and preserve the draft" do
    cases = [
      [ "I never celebrate small wins.", "Celebrate small wins." ],
      [ "I celebrate small wins only when invited.", "Celebrate small wins." ],
      [ "Don't tell people to stop spending.", "Tell people to stop spending." ],
      [ "Don't shame people for spending.", "Don't spend." ],
      [ "Suggest waiting 30 days.", "Suggest waiting 60 days." ],
      [ "Client: I celebrate small wins.", "Celebrate small wins." ]
    ].map { |message, claim| [ message, op("coaching.do", [ claim ], message) ] }
    cases += [
      [ "Sound like a thoughtful teacher. Chamorros always waste money.", op("coaching.do", [ "Chamorros always waste money." ], "Sound like a thoughtful teacher. Chamorros always waste money.") ],
      [ "My voice is warm. No humour.", op("voice.tone_traits", %w[warm direct respectful lighthearted], "My voice is warm.") ],
      [ "I use humour only for celebrations.", op("voice.tone_traits", %w[warm direct respectful lighthearted], "I use humour only for celebrations.") ],
      [ "My voice is warm and practical.", op("voice.tone_traits", [ "warm" ], "My voice is warm and practical.") ],
      [ "Client: My voice is warm.", op("voice.tone_traits", %w[warm direct respectful candid], "My voice is warm.") ],
      [ 'Do not say "You should have known better."', phrase("You should have known better.", "general", 'Do not say "You should have known better."') ],
      [ 'Client: I say "I am hopeless with money."', phrase("I am hopeless with money.", "general", 'I say "I am hopeless with money."') ],
      [ 'I say "Pause".', phrase("Pause", "crisis", 'I say "Pause".') ],
      [ 'I say "Kill yourself".', phrase("Kill yourself", "crisis", 'I say "Kill yourself".') ]
    ]
    cases.each do |message, operation|
      before = @persona.reload.draft_config.deep_dup
      result = run_turn(message, [ operation ])
      assert_equal "ready", result.turn.status, message
      assert_nil result.proposal, message
      assert_equal before, @persona.reload.draft_config, message
    end
  end

  private

  def contract(message)
    Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message)
  end

  def op(path, value, evidence)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "coach_quote", "evidence_quote" => evidence }
  end

  def phrase(text, context, evidence)
    op("phrases", { "text" => text, "meaning" => text, "allowed_contexts" => [ context ], "prohibited_contexts" => [], "frequency" => "rare", "caution" => "" }, evidence).merge("op" => "add_phrase")
  end

  def run_turn(message, operations)
    resolver = Object.new
    resolver.define_singleton_method(:call) do |**|
      Mia::PersonaSetup::ProposalResolver::Result.new(assistant_message: "Review this.", operations:, metadata: {})
    end
    Mia::PersonaSetup::TurnRunner.new(session: @session, actor: @coach, workspace: @workspace, resolver:)
      .call(user_message: message, idempotency_key: SecureRandom.uuid)
  end
end
