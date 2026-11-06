# frozen_string_literal: true

require "test_helper"
require_relative "../support/proposal_guard_test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupRiskSplitTest < ActiveSupport::TestCase
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
      op("voice.tone_traits.x", %w[warm direct respectful lighthearted], "No humour"),
      op("coaching.do", [ "Recommend specific stocks." ], "Recommend specific stocks."),
      phrase("Pause", "crisis", 'I say "Pause"'), phrase("Invented quote", "general", "Not mine"),
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
