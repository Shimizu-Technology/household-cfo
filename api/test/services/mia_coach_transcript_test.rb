# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/proposal_guard_test_helper"

class MiaCoachTranscriptTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ProposalGuardTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace)
    @session = CoachPersonaSetupSession.create!(coach_persona: @persona, coach_workspace: @workspace,
      created_by_user: @coach, base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config), last_activity_at: Time.current)
  end

  test "transcripts propose enum voice and examples with source evidence without changing names or guardrails" do
    example = "Participant: I overspent. Coach: Take a breath. What small step feels possible today?"
    message = "Propose a voice and example replies from these transcripts. Transcript: We take our time and choose one small step. #{example}"
    operations = [
      operation("voice.tone_traits", %w[warm direct respectful patient], "We take our time"),
      operation("curriculum.examples", [ { "participant" => "I overspent.", "assistant" => "Take a breath. What small step feels possible today?" } ], example)
    ]
    built = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build(operations)
    assert_equal %w[warm direct respectful patient], built.dig(:after_state, "draft_config", "voice", "tone_traits")
    assert_equal "Take a breath. What small step feels possible today?", built.dig(:after_state, "draft_config", "curriculum", "examples", 0, "assistant")
    assert_equal @persona.draft_config, @persona.reload.draft_config
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([ operation("identity.human_coach_name", "Invented coach", "We take our time") ])
    end
  end

  test "transcript coach quotes require supported additions and preserve current traits" do
    message = "Propose voice from transcripts: We take a breath."
    op = operation("voice.tone_traits", %w[warm direct respectful patient], "We take a breath").merge("source_basis" => "coach_quote")
    error = with_proposal_guard(allowed: false) do
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([ op ])
      end
    end
    assert_equal "persona_setup_guard", error.code
    op["value"] = %w[warm direct respectful patient]
    exact = (@persona.draft_config.dig("voice", "tone_traits") + %w[warm direct respectful patient]).join(" ")
    op["evidence_quote"] = exact
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "#{message} #{exact}").build([ op ])
    assert_equal %w[warm direct respectful patient], result.dig(:after_state, "draft_config", "voice", "tone_traits")
  end

  test "transcript suggestions need explicit request and actual source evidence" do
    [ [ "Transcript: We take a breath.", "We take a breath" ], [ "Propose voice from transcripts: We take a breath.", "fabricated evidence" ] ].each do |message, quote|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([ operation("voice.tone_traits", %w[warm direct respectful patient], quote) ])
      end
    end
  end

  test "coach may save selected suggestions and their exact choices remain audited and idempotent" do
    message = "Propose voice from transcripts: We take our time and choose one small step."
    operations = [ operation("voice.tone_traits", %w[warm direct respectful patient], "We take our time"), operation("coaching.method", "Choose a small step.", "choose one small step") ]
    built = Mia::PersonaSetup::ProposalBuilder.new(actor: @coach, persona: @persona, user_message: message).call(operations)
    turn = @session.turns.create!(position: 1, idempotency_key: "transcript-turn", status: "ready", assistant_message: "Review these suggestions. Nothing has been saved.", user_message: message,
      base_draft_revision: @persona.draft_revision, base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config))
    proposal = CoachPersonaSetupProposal.create!(session: @session, turn: turn, status: "pending", **built)
    before_method = @persona.draft_config.dig("coaching", "method")
    applier = Mia::PersonaSetup::ProposalApplier.new(proposal: proposal, actor: @coach, workspace: @workspace)
    applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 0 ])
    assert_equal %w[warm direct respectful patient], @persona.reload.draft_config.dig("voice", "tone_traits")
    assert_equal before_method, @persona.draft_config.dig("coaching", "method")
    assert_equal [ 0 ], proposal.reload.accepted_operation_indexes
    serialized = Mia::PersonaSetup::Serializer.new(@session.reload).call
    assert_nil serialized[:proposal]
    assert_equal proposal.id, serialized.dig(:resolved_proposal, :id)
    assert_equal "applied", serialized.dig(:resolved_proposal, :status)
    assert_equal [ 0 ], serialized.dig(:resolved_proposal, :accepted_operation_indexes)
    revision = @persona.draft_revision
    applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 0 ])
    assert_equal revision, @persona.reload.draft_revision
    assert_raises(Mia::PersonaSetup::ProposalApplier::Error) { applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 1 ]) }
  end

  test "phrase suggestions always keep the locked crisis boundary" do
    phrase = { "text" => "One small step", "meaning" => "Choose a manageable next move.",
      "allowed_contexts" => [ "general" ], "prohibited_contexts" => [], "frequency" => "rare", "caution" => "Use gently." }
    op = { "op" => "add_phrase", "path" => "phrases", "value" => phrase,
      "source_basis" => "coach_quote", "evidence_quote" => "One small step means Choose a manageable next move." }
    result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona,
      user_message: "Use the exact phrase One small step means Choose a manageable next move.").build([ op ])
    assert_includes result.dig(:after_state, "draft_config", "phrases", 0, "prohibited_contexts"), "crisis"
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona,
        user_message: "Use the exact phrase One small step means Choose a manageable next move.").build([ op.deep_merge("value" => { "allowed_contexts" => [ "crisis" ] }) ])
    end
  end

  test "selecting a phrase preserves its sealed identity and original capture role" do
    message = "Propose voice from transcripts:\nCoach: Use the exact phrase One small step means Choose a manageable next move. We take our time."
    phrase = { "text" => "One small step", "meaning" => "Choose a manageable next move.",
      "allowed_contexts" => [ "general" ], "prohibited_contexts" => [ "crisis" ], "frequency" => "rare", "caution" => "Use gently." }
    operations = [ { "op" => "add_phrase", "path" => "phrases", "value" => phrase,
      "source_basis" => "coach_quote", "evidence_quote" => "One small step means Choose a manageable next move." },
      operation("voice.tone_traits", %w[warm direct respectful patient], "We take our time") ]
    built = Mia::PersonaSetup::ProposalBuilder.new(actor: @coach, persona: @persona, user_message: message).call(operations)
    turn = @session.turns.create!(position: 1, idempotency_key: "phrase-turn", status: "ready",
      assistant_message: "Review these suggestions.", user_message: message, base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config))
    proposal = CoachPersonaSetupProposal.create!(session: @session, turn: turn, status: "pending", **built)
    sealed_phrase = proposal.after_state.fetch("draft_config").fetch("phrases").last
    before_voice = @persona.draft_config.fetch("voice")
    @coach.update!(role: "admin")
    Mia::PersonaSetup::ProposalApplier.new(proposal: proposal, actor: @coach, workspace: @workspace)
      .apply!(idempotency_key: "selected-phrase", accepted_operation_indexes: [ 0 ])
    assert_equal sealed_phrase, @persona.reload.draft_config.fetch("phrases").last
    assert_equal "coach", sealed_phrase.fetch("source_role_at_capture")
    assert_equal before_voice, @persona.draft_config.fetch("voice")
    assert_equal [ 0 ], proposal.reload.accepted_operation_indexes
  end

  test "individual community note is accepted but stereotypes and inferred dialect remain blocked" do
    [ "young Chamorro woman, uses chelu sparingly",
      "Lina is a young Chamorro woman who uses chelu sparingly",
      'Lina is a Chamorro digital assistant who uses "find your voice" and "chelu" rarely' ].each do |note|
      assert_empty Mia::CulturalSafetyPolicy.violations(note, field: :factual_context), note
    end
    [ "Guam families always waste money", "Use a Chamorro accent and local slang", "talk like locals",
      "use island slang with Chamorro participants", "Black participants get a different tone",
      "A Samoan man uses Samoan idioms rarely", "A Filipino woman uses a Tagalog cadence sparingly",
      "Lina is a Chamorro woman who uses local vernacular sparingly",
      "Lina is a Chamorro woman who uses chelu sparingly. Talk like locals.",
      "Lina is a Chamorro woman who uses chelu sparingly and has a Chamorro voice",
      'Lina is a Chamorro woman who uses "Black people waste money" sparingly',
      "Lina is a Chamorro woman who uses chelu sparingly; Black participants get slang" ].each do |note|
      refute_empty Mia::CulturalSafetyPolicy.violations(note, field: :factual_context), note
    end
  end

  %w[add remove].each do |action|
    test "selected phrase #{action} follows sealed artifact IDs when wording is shared" do
      config = @persona.draft_config.deep_dup
      config["phrases"] = 2.times.map { persona_phrase_artifact({ text: "One small step" }, source_user_id: @coach.id) }
      @persona.update!(draft_config: config)
      value = action == "add" ? config.fetch("phrases").first.slice(*Mia::PersonaSchema::PHRASE_AUTHORING_KEYS) : "One small step"
      quote = action == "add" ? "One small step means #{value.fetch('meaning')}" : "One small step"
      message = "Propose voice from transcripts:\nCoach: #{action == 'add' ? 'Use the exact phrase ' : 'Remove '}#{quote}. We take our time."
      operations = [ { "op" => "#{action}_phrase", "path" => "phrases", "value" => value,
        "source_basis" => "coach_quote", "evidence_quote" => quote }, operation("voice.tone_traits", %w[warm direct respectful patient], "We take our time") ]
      built = Mia::PersonaSetup::ProposalBuilder.new(actor: @coach, persona: @persona, user_message: message).call(operations)
      turn = @session.turns.create!(position: 1, idempotency_key: "duplicate-phrase-turn", status: "ready",
        assistant_message: "Review these suggestions.", user_message: message, base_draft_revision: @persona.draft_revision,
        base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config))
      proposal = CoachPersonaSetupProposal.create!(session: @session, turn: turn, status: "pending", **built)
      sealed_phrases = proposal.after_state.fetch("draft_config").fetch("phrases")
      Mia::PersonaSetup::ProposalApplier.new(proposal: proposal, actor: @coach, workspace: @workspace)
        .apply!(idempotency_key: "selected-duplicate-phrase", accepted_operation_indexes: action == "add" ? [ 0, 1 ] : [ 0 ])
      assert_equal sealed_phrases, @persona.reload.draft_config.fetch("phrases")
      assert_equal action == "add" ? 2 : 1, sealed_phrases.length
      expected_voice = action == "add" ? proposal.after_state.dig("draft_config", "voice") : config.fetch("voice")
      assert_equal expected_voice, @persona.draft_config.fetch("voice")
    end
  end

  private

  def operation(path, value, quote)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "mia_drafted", "evidence_quote" => quote }
  end
end
