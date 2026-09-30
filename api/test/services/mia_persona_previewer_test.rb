# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaPreviewerTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @persona = create_persona(name: "Preview assistant")
  end

  test "returns a clearly sourced reply only when the exact draft reached the live model" do
    responder = fake_responder(
      source: "live_model",
      reply: "Protect the household baseline first. Review the confirmed plan before making the purchase."
    )

    result = Mia::PersonaPreviewer.new(
      persona: @persona,
      sample_prompt: "Can I afford this purchase?",
      responder: responder
    ).call

    assert_equal "ready", result.fetch(:status)
    assert_equal "live_model", result.fetch(:source)
    assert_equal "Can I afford this purchase?", responder.received_prompt
    assert_includes result.fetch(:notice), "exact draft"
    assert_includes result.fetch(:sample_reply), "household baseline"
  end

  test "does not present a deterministic fallback as the answer to the coach test message" do
    responder = fake_responder(
      source: "deterministic_fallback",
      reply: "This generic fallback did not evaluate the requested persona behavior."
    )

    result = Mia::PersonaPreviewer.new(
      persona: @persona,
      sample_prompt: "How would you coach me through this?",
      responder: responder
    ).call

    assert_equal "unavailable", result.fetch(:status)
    assert_equal "deterministic_fallback", result.fetch(:source)
    assert_nil result.fetch(:sample_reply)
    assert_includes result.fetch(:notice), "No canned reply"
  end

  test "shows the deterministic crisis boundary because it is the actual preview behavior" do
    responder = fake_responder(
      source: "deterministic_safety",
      reply: "Call or text 988 now."
    )

    result = Mia::PersonaPreviewer.new(
      persona: @persona,
      sample_prompt: "I want to die",
      responder: responder
    ).call

    assert_equal "ready", result.fetch(:status)
    assert_equal "deterministic_safety", result.fetch(:source)
    assert_equal "Call or text 988 now.", result.fetch(:sample_reply)
    assert_includes result.fetch(:notice), "Safety rules"
  end

  test "blank test messages compile without inventing a preview reply" do
    result = Mia::PersonaPreviewer.new(persona: @persona, sample_prompt: "  ").call

    assert_equal "not_requested", result.fetch(:status)
    assert_equal "not_requested", result.fetch(:source)
    assert_nil result.fetch(:sample_prompt)
    assert_nil result.fetch(:sample_reply)
  end

  private

  def fake_responder(source:, reply:)
    Object.new.tap do |responder|
      responder.define_singleton_method(:response_source) { source }
      responder.define_singleton_method(:received_prompt) { @received_prompt }
      responder.define_singleton_method(:call) do |prompt, **_options|
        @received_prompt = prompt
        reply
      end
    end
  end
end
