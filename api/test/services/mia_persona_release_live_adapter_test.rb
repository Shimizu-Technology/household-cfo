# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaReleaseLiveAdapterTest < ActiveSupport::TestCase
  include PersonaTestHelper

  class FakeResponder
    attr_reader :response_source, :received_context

    def initialize(source:, output:)
      @response_source = source
      @output = output
    end

    def call(_prompt, context:, draft_capable:)
      @received_context = JSON.parse(context)
      raise "release evaluation became draft capable" if draft_capable

      @output
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
    assert_equal candidate.manifest_digest, response.metadata.fetch("candidate_digest")
    assert_equal "no_participant_or_household_data", response.metadata.fetch("privacy_mode")
    assert_equal candidate.config_snapshot.dig("identity", "assistant_name"), captured_runtime.name
    assert_equal true, responder.received_context.fetch("evaluation_mode")
    assert_empty responder.received_context.fetch("metrics")
    assert_empty responder.received_context.dig("debts", "records")
    assert_operator response.output.length, :<=, Mia::PersonaRelease::LiveBehavioralAdapter::MAX_OUTPUT_CHARS
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
