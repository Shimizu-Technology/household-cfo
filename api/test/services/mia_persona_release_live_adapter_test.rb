# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaReleaseLiveAdapterTest < ActiveSupport::TestCase
  include PersonaTestHelper

  class FakeResponder
    attr_reader :response_source, :received_context, :model_identifier, :provider_request_id

    def initialize(source:, output:, model_identifier: "anthropic/claude-sonnet-4.5", provider_request_id: "gen-test-123")
      @response_source = source
      @output = output
      @model_identifier = model_identifier
      @provider_request_id = provider_request_id
    end

    def call(_prompt, context:, draft_capable:)
      @received_context = JSON.parse(context)
      raise "release evaluation became draft capable" if draft_capable

      @output
    end
  end

  class UnprovenLiveAdapter < Mia::PersonaRelease::BehavioralAdapter
    def kind = "unproven_live_test"

    def call(evaluation_case:, persona:, candidate:)
      Response.new(
        output: "Review the facts and options before choosing the next step.",
        metadata: { "source" => "live_model", "candidate_digest" => candidate.manifest_digest },
        fallback_only: false
      )
    end
  end

  test "custom evaluation uses the exact candidate persona with bounded no-household context" do
    owner = persona_user
    persona = create_persona(creator: owner)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: owner).call!
    evaluation_case = custom_case(persona, owner)
    responder = FakeResponder.new(source: "live_model", output: "Review the exact facts, then choose one next step.")
    captured_runtime = nil
    adapter = Mia::PersonaRelease::LiveBehavioralAdapter.new(
      responder_factory: lambda do |runtime|
        captured_runtime = runtime
        responder
      end
    )

    response = adapter.call(evaluation_case: evaluation_case, persona: persona, candidate: candidate)

    refute response.fallback_only
    assert_equal "live_model", response.metadata.fetch("source")
    assert_equal "anthropic/claude-sonnet-4.5", response.metadata.fetch("model_identifier")
    assert_equal "gen-test-123", response.metadata.fetch("provider_request_id")
    assert_equal candidate.manifest_digest, response.metadata.fetch("candidate_digest")
    assert_equal "no_participant_or_household_data", response.metadata.fetch("privacy_mode")
    assert_equal candidate.config_snapshot.dig("identity", "assistant_name"), captured_runtime.name
    assert_equal true, responder.received_context.fetch("evaluation_mode")
    assert_empty responder.received_context.fetch("metrics")
    assert_empty responder.received_context.dig("debts", "records")
    assert_operator response.output.length, :<=, Mia::PersonaRelease::LiveBehavioralAdapter::MAX_OUTPUT_CHARS
  end

  test "custom evaluation fails closed without concrete provider provenance" do
    owner = persona_user
    persona = create_persona(creator: owner)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: owner).call!
    evaluation_case = custom_case(persona, owner)

    [
      FakeResponder.new(source: "live_model", output: "Review the facts.", model_identifier: nil),
      FakeResponder.new(source: "live_model", output: "Review the facts.", provider_request_id: nil),
      FakeResponder.new(source: "live_model", output: "Review the facts.", provider_request_id: "bad request id")
    ].each do |responder|
      response = Mia::PersonaRelease::LiveBehavioralAdapter.new(responder_factory: ->(_runtime) { responder })
        .call(evaluation_case: evaluation_case, persona: persona, candidate: candidate)
      assert response.fallback_only
      assert_empty response.output
      assert_equal "invalid_provider_provenance", response.metadata.fetch("source")
    end
  end

  test "custom evaluation discards fallback and oversized model output" do
    owner = persona_user
    persona = create_persona(creator: owner)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: owner).call!
    evaluation_case = custom_case(persona, owner)

    [
      FakeResponder.new(source: "deterministic_fallback", output: "A canned answer"),
      FakeResponder.new(source: "live_model", output: "x" * (Mia::PersonaRelease::LiveBehavioralAdapter::MAX_OUTPUT_CHARS + 1))
    ].each do |responder|
      adapter = Mia::PersonaRelease::LiveBehavioralAdapter.new(responder_factory: ->(_runtime) { responder })
      response = adapter.call(evaluation_case: evaluation_case, persona: persona, candidate: candidate)
      assert response.fallback_only
      assert_empty response.output
    end
  end

  test "hybrid run cannot pass a custom case on generic fallback output" do
    owner = persona_user
    persona = create_persona(creator: owner)
    evaluation_case = custom_case(persona, owner)
    responder = FakeResponder.new(source: "deterministic_fallback", output: "Review the facts and options.")
    live = Mia::PersonaRelease::LiveBehavioralAdapter.new(responder_factory: ->(_runtime) { responder })
    adapter = Mia::PersonaRelease::HybridBehavioralAdapter.new(live: live)

    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: adapter).call!
    custom_result = run.results.find_by!(coach_persona_evaluation_case_id: evaluation_case.id)

    assert_equal "failed", run.status
    assert custom_result.fallback_only?
    assert_empty custom_result.output
    assert_equal "deterministic_fallback", custom_result.adapter_metadata.fetch("source")
    refute run.passed_and_valid?
  end

  test "runner cannot pass a custom case when an adapter omits provider provenance" do
    owner = persona_user
    persona = create_persona(creator: owner)
    evaluation_case = custom_case(persona, owner)
    adapter = Mia::PersonaRelease::HybridBehavioralAdapter.new(live: UnprovenLiveAdapter.new)

    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: adapter).call!
    result = run.results.find_by!(coach_persona_evaluation_case_id: evaluation_case.id)

    assert_equal "failed", run.status
    assert result.fallback_only?
    assert_equal "live_model", result.adapter_metadata.fetch("source")
    assert_nil result.adapter_metadata["model_identifier"]
    assert_nil result.adapter_metadata["provider_request_id"]
    refute run.passed_and_valid?
  end

  private

  def custom_case(persona, owner)
    record = persona.evaluation_cases.new(
      coach_workspace: persona.coach_workspace,
      created_by_user: owner,
      name: "Candidate behavior",
      case_kind: "custom",
      prompt: "What should this fictional household review?",
      assertions: [ { "type" => "includes", "value" => "review" }, { "type" => "not_fallback" } ],
      required: false,
      active: true,
      request_key: "live-adapter-#{SecureRandom.uuid}",
      request_fingerprint: "1" * 64
    )
    record.case_digest = CoachPersonaEvaluationCase.digest_for(record)
    record.save!
    record
  end
end
