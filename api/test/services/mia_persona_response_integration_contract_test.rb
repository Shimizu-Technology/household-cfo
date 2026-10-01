# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaResponseIntegrationContractTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    coach = persona_user
    config = persona_configuration(assistant_name: "Coach Lila", coach_name: "Coach June")
    config["culture"] = config.fetch("culture").merge(
      "locale_label" => "Southern United States",
      "context" => "Program schedules and service references must use the participant's confirmed state."
    )
    config["phrases"] = [
      Mia::PersonaSchema.build_phrase_artifact({
        "text" => "y'all",
        "meaning" => "a natural second-person plural",
        "allowed_contexts" => [ "routine" ],
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "as_needed",
        "caution" => "Use naturally and sparingly."
      }, source_user_id: coach.id)
    ]
    persona = CoachPersona.create!(
      name: "Coach Lila",
      description: "Response integration contract fixture.",
      draft_config: config,
      created_by_user: coach
    )
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    version = publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil
    )
    @runtime = Mia::RuntimePersona.new(version)
  end

  test "language policy keeps an approved custom phrase in an allowed context" do
    answer = Mia::LanguagePolicy.new(
      user_message: "What should our household focus on this month?",
      persona: @runtime
    ).sanitize("Y'all should review the confirmed plan first.")

    assert_equal "Y'all should review the confirmed plan first.", answer
  end

  test "language policy removes a recently repeated custom phrase" do
    answer = Mia::LanguagePolicy.new(
      user_message: "What should our household focus on this month?",
      history: [ { role: "assistant", content: "Y'all already checked the plan." } ],
      persona: @runtime
    ).sanitize("Y'all should review the confirmed plan first.")

    assert_equal "You should review the confirmed plan first.", answer
  end

  test "custom phrase repetition matches straight and curly apostrophes" do
    answer = Mia::LanguagePolicy.new(
      user_message: "What should our household focus on this month?",
      history: [ { role: "assistant", content: "Y’all already checked the plan." } ],
      persona: @runtime
    ).sanitize("Y'all should review the confirmed plan first.")

    assert_equal "You should review the confirmed plan first.", answer
  end

  test "ordinary auxiliary-led questions remain unchanged when no phrase was removed" do
    answer = Mia::LanguagePolicy.new(
      user_message: "Can you help me understand the plan?",
      persona: @runtime
    ).sanitize("Are you asking about the current month?")

    assert_equal "Are you asking about the current month?", answer
  end

  test "custom phrase matching handles dash spacing and canonical Unicode forms" do
    dash_runtime = runtime_with_phrase("steady-step")
    unicode_runtime = runtime_with_phrase("café check")

    dash_answer = Mia::LanguagePolicy.new(
      user_message: "What should we do next?",
      history: [ { role: "assistant", content: "Take one steady—step today." } ],
      persona: dash_runtime
    ).sanitize("Take one steady - step today.")
    unicode_answer = Mia::LanguagePolicy.new(
      user_message: "What should we do next?",
      history: [ { role: "assistant", content: "Start with a cafe\u0301 check." } ],
      persona: unicode_runtime
    ).sanitize("Start with a café check.")

    assert_equal "Take one today.", dash_answer
    assert_equal "Start with a.", unicode_answer
  end

  test "language policy gives a prohibited crisis context precedence over user repetition" do
    [ "I want to die, y'all", "I can't go on with this debt anymore, y'all" ].each do |message|
      answer = Mia::LanguagePolicy.new(
        user_message: message,
        persona: @runtime
      ).sanitize("Y'all, call or text 988 now.")

      assert_equal "Call or text 988 now.", answer
    end
  end

  test "prohibited contexts remove phrase typography variants" do
    answer = Mia::LanguagePolicy.new(
      user_message: "I want to die",
      persona: @runtime
    ).sanitize("Y’all, call or text 988 now.")

    assert_equal "Call or text 988 now.", answer
  end

  test "custom personas remove known cultural language unless the coach approved it" do
    unapproved = Mia::LanguagePolicy.new(
      user_message: "What should our household focus on this month?",
      persona: @runtime
    ).sanitize("Håfa Adai, y'all should review the confirmed plan first.")
    approved_runtime = runtime_with_phrase("Håfa Adai", allowed_contexts: [ "greeting" ])
    approved = Mia::LanguagePolicy.new(
      user_message: "Hafa Adai, can you help?",
      persona: approved_runtime
    ).sanitize("Håfa Adai! Let's review the confirmed plan.")

    assert_equal "Y'all should review the confirmed plan first.", unapproved
    assert_equal "Håfa Adai! Let's review the confirmed plan.", approved
  end

  test "runtime persona fallbacks never inherit legacy Guam cultural language" do
    assert_equal "That purse isn’t in the cards right now.", @runtime.fallback_response(:spending).split(" If ").first
    refute_match(/lanya|chelu|h[åa]fa adai|umbee/i, @runtime.fallback_response(:spending))
    refute_match(/lanya|chelu|h[åa]fa adai|umbee/i, @runtime.uncertainty_line)
  end

  test "narrator prompt and sanitizer use the supplied runtime persona" do
    narrator = HouseholdFinance::MiaNarrator.new(
      user_message: "What should our household focus on this month?",
      answer_packet: {
        kind: "coaching",
        fallback_response: "Review the confirmed plan first.",
        write_state: "no_write"
      },
      api_key: "test-key",
      persona: @runtime
    )

    payload = narrator.send(:payload)
    system_prompts = payload.fetch(:messages).select { |message| message.fetch(:role) == "system" }.map { |message| message.fetch(:content) }

    assert_includes system_prompts, @runtime.system_prompt
    assert system_prompts.any? { |prompt| prompt.include?("Southern United States") }
    assert_includes payload.fetch(:messages).third.fetch(:content), "response layer for Coach Lila"
    assert_includes payload.fetch(:messages).last.fetch(:content), "Write Coach Lila's final response now."
    assert_includes payload.fetch(:messages).last.fetch(:content), "assigned_assistant_is_coach_assistant"
    refute_includes payload.fetch(:messages).last.fetch(:content), "mia_is_coach_assistant"
    assert_equal "Y'all should review the confirmed plan first.", narrator.send(:sanitize_narration, "Coach Lila: Y'all should review the confirmed plan first.")
  end

  test "narrator rejects provider output that violates the custom response shape" do
    narrator = HouseholdFinance::MiaNarrator.new(
      user_message: "What should our household focus on this month?",
      answer_packet: {
        kind: "coaching",
        fallback_response: "Review the confirmed plan first.",
        write_state: "no_write"
      },
      api_key: "test-key",
      persona: @runtime
    )
    narrator.define_singleton_method(:openrouter_response) { "Only one sentence." }

    assert_equal :persona_response_shape, narrator.send(:narration_rejection_reason, "Only one sentence.")
    assert_equal "Review the confirmed plan first.", narrator.call
  end

  test "custom assistant may accurately describe a pending draft but not a confirmed write" do
    narrator = HouseholdFinance::MiaNarrator.new(
      user_message: "Draft this purchase for review.",
      answer_packet: {
        kind: "transaction_draft",
        fallback_response: "Coach Lila drafted the purchase for review. Confirm it only if the details are right.",
        write_state: "pending_review"
      },
      api_key: "test-key",
      persona: @runtime
    )

    refute narrator.send(:dynamic_persona_write_claim?, "Coach Lila drafted the purchase for review.")
    assert narrator.send(:dynamic_persona_write_claim?, "Coach Lila recorded the purchase in actuals.")
  end

  test "responder sends the supplied runtime persona prompt to the provider" do
    captured_requests = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.generate(choices: [ { message: { content: "Review the confirmed plan first. Then choose one concrete next move." } } ])
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_requests << request
      response
    end
    start_stub = lambda do |*_arguments, **_options, &block|
      block.call(http)
    end

    with_net_http_start(start_stub) do
      result = Demo::MiaResponder.new(api_key: "test-key", persona: @runtime).call(
        "How should our household prepare?",
        context: JSON.generate(basis: "approved test facts")
      )
      assert_equal "Review the confirmed plan first. Then choose one concrete next move.", result
    end

    payload = JSON.parse(captured_requests.sole.body)
    system_prompts = payload.fetch("messages").select { |message| message.fetch("role") == "system" }.map { |message| message.fetch("content") }
    assert_includes system_prompts, @runtime.system_prompt
    assert system_prompts.any? { |prompt| prompt.include?("Southern United States") }
  end

  test "responder replaces provider output that violates the custom response shape with a safe fallback" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.generate(choices: [ { message: { content: "Only one sentence." } } ])
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start_stub = lambda do |*_arguments, **_options, &block|
      block.call(http)
    end

    result = with_net_http_start(start_stub) do
      Demo::MiaResponder.new(api_key: "test-key", persona: @runtime).call(
        "How should our household prepare?",
        context: JSON.generate(basis: "approved test facts")
      )
    end

    refute_equal "Only one sentence.", result
    assert_includes result, @runtime.uncertainty_line
    assert_includes result, "protects the household baseline"
  end

  private

  def runtime_with_phrase(text, allowed_contexts: [ "general" ])
    coach = persona_user
    config = persona_configuration(assistant_name: "Coach Kai", coach_name: "Coach June")
    config["phrases"] = [
      Mia::PersonaSchema.build_phrase_artifact({
        "text" => text,
        "meaning" => "A coach-approved expression.",
        "allowed_contexts" => allowed_contexts,
        "prohibited_contexts" => [ "crisis" ],
        "frequency" => "sparing",
        "caution" => "Use naturally and sparingly."
      }, source_user_id: coach.id)
    ]
    persona = CoachPersona.create!(
      name: "Coach Kai",
      description: "Phrase normalization fixture.",
      draft_config: config,
      created_by_user: coach
    )
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    version = publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil
    )
    Mia::RuntimePersona.new(version)
  end

  def with_net_http_start(replacement)
    singleton = Net::HTTP.singleton_class
    original = singleton.instance_method(:start)
    singleton.define_method(:start, replacement)
    yield
  ensure
    singleton.send(:remove_method, :start) if singleton.method_defined?(:start)
    singleton.define_method(:start, original)
  end
end
