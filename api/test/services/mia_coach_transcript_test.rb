# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaCoachTranscriptTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace)
    @session = CoachPersonaSetupSession.create!(coach_persona: @persona, coach_workspace: @workspace,
      created_by_user: @coach, base_draft_revision: @persona.draft_revision,
      base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config), last_activity_at: Time.current)
  end

  test "transcripts propose enum voice and examples with source evidence without changing names or guardrails" do
    message = "Propose a voice and example replies from these transcripts. Transcript: We take a breath and choose one small step."
    operations = [
      operation("voice.tone_traits", [ "patient", "warm" ], "We take a breath"),
      operation("curriculum.examples", [ { "participant" => "I overspent.", "assistant" => "Take a breath. What small step feels possible today?" } ], "choose one small step")
    ]
    built = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build(operations)
    assert_equal [ "patient", "warm" ], built.dig(:after_state, "draft_config", "voice", "tone_traits")
    assert_equal "Take a breath. What small step feels possible today?", built.dig(:after_state, "draft_config", "curriculum", "examples", 0, "assistant")
    assert_equal @persona.draft_config, @persona.reload.draft_config
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
      Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([operation("identity.human_coach_name", "Invented coach", "We take a breath")])
    end
  end

  test "transcript suggestions need explicit request and actual source evidence" do
    [ [ "Transcript: We take a breath.", "We take a breath" ], [ "Propose voice from transcripts: We take a breath.", "fabricated evidence" ] ].each do |message, quote|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message).build([operation("voice.tone_traits", [ "patient" ], quote)])
      end
    end
  end

  test "coach may save selected suggestions and their exact choices remain audited and idempotent" do
    message = "Propose voice from transcripts: We take a breath and choose one small step."
    operations = [operation("voice.tone_traits", [ "patient" ], "We take a breath"), operation("coaching.method", "Choose a small step.", "choose one small step")]
    built = Mia::PersonaSetup::ProposalBuilder.new(actor: @coach, persona: @persona, user_message: message).call(operations)
    turn = @session.turns.create!(position: 1, idempotency_key: "transcript-turn", status: "ready", assistant_message: "Review these suggestions. Nothing has been saved.", user_message: message,
      base_draft_revision: @persona.draft_revision, base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config))
    proposal = @session.proposals.create!(turn: turn, status: "pending", **built)
    before_method = @persona.draft_config.dig("coaching", "method")
    applier = Mia::PersonaSetup::ProposalApplier.new(proposal: proposal, actor: @coach, workspace: @workspace)
    applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 0 ])
    assert_equal [ "patient" ], @persona.reload.draft_config.dig("voice", "tone_traits")
    assert_equal before_method, @persona.draft_config.dig("coaching", "method")
    assert_equal [ 0 ], proposal.reload.accepted_operation_indexes
    revision = @persona.draft_revision
    applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 0 ])
    assert_equal revision, @persona.reload.draft_revision
    assert_raises(Mia::PersonaSetup::ProposalApplier::Error) { applier.apply!(idempotency_key: "selected-choices", accepted_operation_indexes: [ 1 ]) }
  end

  test "individual community note is accepted but stereotypes and inferred dialect remain blocked" do
    note = "young Chamorro woman, uses chelu sparingly"
    assert_empty Mia::CulturalSafetyPolicy.violations(note, field: :factual_context)
    refute_empty Mia::CulturalSafetyPolicy.violations("Guam families always waste money", field: :factual_context)
    refute_empty Mia::CulturalSafetyPolicy.violations("Use a Chamorro accent and local slang", field: :factual_context)
  end

  private

  def operation(path, value, quote)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "mia_drafted", "evidence_quote" => quote }
  end
end
