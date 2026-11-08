# frozen_string_literal: true

require "test_helper"

require_relative "../support/reply_guard_test_helper"

class MiaResponseShapeRewriteIntegrationTest < ActiveSupport::TestCase
  include ReplyGuardTestHelper
  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  SAMPLE = "I want to spend $100 this weekend. How can I decide?"
  LONG_REPLY = "Wanting something is normal. Pause before deciding. Check your basics first. Keep required payments covered. What is the purchase for?"
  VALID_REPLY = "Wanting something is normal. Protect your basics and required payments first. What is the purchase for?"
  FALLBACK = "Use the approved reference answer."

  setup do
    HouseholdFinance::ParticipantMessageReader::Current.reset
    Mia::ReplyGuard.singleton_class.define_method(:call) do |**args|
      flags = case args[:reply]
      when /That purchase works|You can (?:comfortably )?afford/ then [ "purchase_approval" ]
      when /I recorded/ then [ "action_claim" ]
      else []
      end
      Mia::ReplyGuard::Result.new(flags)
    end
    @persona = Mia::RuntimePersona.for_preview(config: JSON.parse(file_fixture("mia_coach_short_config.json").read), persona_id: 42, draft_revision: 1)
    # Capacity has its own DB-lock suite. These fake transport replies exercise
    # validation and retries even when this machine's DB checkout exceeds 1s.
    singleton = HouseholdFinance::MiaProviderAdmission.singleton_class
    @original_admission = singleton.instance_method(:with_slot)
    singleton.define_method(:with_slot) { |**_, &block| block.call }
  end

  teardown do
    HouseholdFinance::MiaProviderAdmission.singleton_class.define_method(:with_slot, @original_admission)
  end

  test "figures and phrase leave room for the decision and question" do
    long = "Hold off until it is funded. The call is yours. What would cover it?"
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE, validator: ->(_text) { nil }, fixed_prefix: "These are plan figures. Chelu, pump the brakes.") { long }
    assert_nil result.rejection_reason
    assert_equal "The call is yours. What would cover it?", result.content
  end

  test "exact product digits are not purchase figures but extra prices still fail" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "thinkin of gettin a 700 ps5 on my card, i dont have the cash", persona: @persona,
      answer_packet: { kind: "purchase_scenario", purchase_prefix: "The plan has room for review.", fallback_response: "Hold off on this purchase." })
    HouseholdFinance::ParticipantMessageReader::Current.message = "thinkin of gettin a 700 ps5 on my card, i dont have the cash"
    HouseholdFinance::ParticipantMessageReader::Current.reading = HouseholdFinance::ParticipantMessageReader::Result.new("none", [], true, {}, false, [], true, false, false, {}, false, { "item" => "ps5", "amount" => "700" }, {}, {}, "none", "purchase_question")
    assert_equal "Hold off on the product.", narrator.send(:coaching_without_product_names, "Hold off on the PS5.")
    assert_includes narrator.send(:coaching_without_product_names, "The PS5 leaves $30."), "$30"
    assert_includes narrator.send(:coaching_without_product_names, "The PS50 leaves $30."), "PS50"
    assert_includes narrator.send(:coaching_without_product_names, "It leaves 100k."), "100k"
  end

  test "fit removes multiple redundant boundary sentences and revalidates" do
    long = "Hold off on credit. Check what is covered before ordering. You cannot cover another payment yet. The call is yours. What could you save first?"
    validations = []
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE,
      validator: ->(text) { validations << text; nil }, fixed_prefix: "These are plan figures.") { long }
    assert_nil result.rejection_reason
    assert_includes result.content, "The call is yours."
    assert_includes result.content, "What could you save first?"
    assert_equal result.content, validations.last
  end

  test "R2 fitting preserves the cautious stance" do
    long = "Hold off for now. Before ordering, remove your saved card. The decision is yours. What would help tonight?"
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE, validator: ->(_content) { nil }, fixed_prefix: "These are plan figures.") { long }
    assert_includes result.content, "Hold off for now."
  end

  test "a rewrite that stays too long after server figures is fitted from the middle" do
    max = @persona.response_shape.fetch("max_sentences")
    long = (1..(max - 1)).map { |index| "Sentence number #{index} stays calm." }.join(" ") + " What matters most?"
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE, validator: ->(_content) { nil }, fixed_prefix: "The plan has room for review.") { long }
    assert_nil result.rejection_reason
    sentences = result.content.split(Mia::ResponseShapePolicy::SENTENCE_BOUNDARY)
    assert_equal max - 1, sentences.length
    assert_equal "Sentence number 1 stays calm.", sentences.first
    assert_equal "What matters most?", sentences.last
  end

  test "fitting preserves the participant decision and concrete next step" do
    long = "A sale adds urgency. Before ordering, remove your saved card. The decision is yours. What would help tonight?"
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE, validator: ->(_content) { nil }, fixed_prefix: "These are plan figures.") { long }
    assert_nil result.rejection_reason
    assert_includes result.content, "The decision is yours."
    assert_includes result.content, "What would help tonight?"
  end

  test "a fitted rewrite still fails its validators" do
    max = @persona.response_shape.fetch("max_sentences")
    long = (1..(max - 1)).map { |index| "Sentence number #{index} stays calm." }.join(" ") + " What matters most?"
    result = Mia::ResponseShapeRewriter.call(long, persona: @persona, user_message: SAMPLE, validator: ->(_content) { :unsafe }, fixed_prefix: "The plan has room for review.") { long }
    assert_equal :unsafe, result.rejection_reason
  end

  test "preview repairs one safe length miss with exact draft and final provider provenance" do
    requests = []
    with_provider_replies([ LONG_REPLY, VALID_REPLY ], requests) do
      responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona, strict_privacy: true)
      assert_equal VALID_REPLY, responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json)
      assert_equal "live_model", responder.response_source
      assert_equal "gen-shape-2", responder.provider_request_id
      assert_equal "test-model-2", responder.model_identifier
    end
    assert_equal 2, requests.length
    requests.each do |payload|
      assert_equal({ "data_collection" => "deny", "allow_fallbacks" => false, "require_parameters" => true }, payload.fetch("provider"))
      assert_empty payload.fetch("tools")
      assert_includes payload.dig("messages", 0, "content"), "3-4 sentences"
    end
    assert_equal LONG_REPLY, requests.last.fetch("messages")[-2].fetch("content")
    assert_includes requests.last.fetch("messages").last.fetch("content"), "Keep every fact"
    assert_includes requests.last.fetch("messages").last.fetch("content"), "add nothing"
  end

  [ true, false ].each do |preview|
    test "claim rewrite reruns every check for #{preview ? 'preview' : 'participant'}" do
      original = "That purchase works. Protect food and housing first. Which category would fund it?"
      requests = []
      context = { preview_mode: preview, metrics: {}, debts: { records: [] } }.to_json
      with_provider_replies([ original, VALID_REPLY ], requests) do
        responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
        assert_equal VALID_REPLY, responder.call(SAMPLE, context: context)
        assert_equal "live_model", responder.response_source
      end
      assert_equal 2, requests.length
      assert_includes requests.last.fetch("messages").last.fetch("content"), "purchase_approval"
    end
  end

  test "claim rewrite cannot bypass amount or approval checks and never retries twice" do
    original = "That purchase works. Protect food and housing first. Which category would fund it?"
    [ "You can afford it. Protect food first. Which category would fund it?", "Your income is $999. Protect food first. Which category would fund it?" ].each do |rewrite|
      requests = []
      with_provider_replies([ original, rewrite ], requests) do
        responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
        refute_equal rewrite, responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json)
        assert_equal :reply_rejected, responder.fallback_reason
      end
      assert_equal 2, requests.length
    end
  end

  test "participant purchase narration rejects figures and shares one approval rewrite" do
    unsafe = "You can afford it. Protect your bills first. Which account would you use?"
    narrator, attempts = narrator_with_replies(HouseholdFinance::MiaNarrator, [ unsafe, unsafe ], message: "Can I afford a $300 stroller?")
    fallback = "The $300 purchase would leave $1,105 in the plan; your November plan leaves $1,405 before it. Your account balances are unknown. Which account would you use?"
    narrator.instance_variable_get(:@answer_packet).merge!(kind: "purchase_scenario", fallback_response: fallback)
    assert_equal narrator.send(:fallback_response), narrator.call
    assert_equal 2, attempts.length
    assert_equal :reply_guard, narrator.rejection_reason
  end

  test "preview rewrite still outside range falls back after exactly two requests" do
    requests = []
    with_provider_replies([ LONG_REPLY, "Still too short." ], requests) do
      responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
      refute_equal "Still too short.", responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json)
      assert_equal :reply_rejected, responder.fallback_reason
      assert_equal "deterministic_fallback", responder.response_source
      assert_empty responder.supplied_content_context
    end
    assert_equal 2, requests.length
  end

  test "preview rejects an unverified amount introduced by its rewrite" do
    requests = []
    with_provider_replies([ LONG_REPLY, "Your income is $999. Protect the basics first. Review the plan." ], requests) do
      responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
      refute_includes responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json), "$999"
      assert_equal :reply_rejected, responder.fallback_reason
    end
    assert_equal 2, requests.length
  end

  [ HouseholdFinance::MiaNarrator, SavingsChallenge::Narrator ].each do |narrator_class|
    test "#{narrator_class} shares one rewrite then accepts the safe answer" do
      narrator, attempts = narrator_with_replies(narrator_class, [ LONG_REPLY, VALID_REPLY ])
      assert_equal VALID_REPLY, narrator.call
      assert_equal 2, attempts.length
      assert_equal LONG_REPLY, attempts.last.fetch(:messages)[-2].fetch(:content)
      assert_includes attempts.last.fetch(:messages).last.fetch(:content), "3-4 sentences"
    end

    test "#{narrator_class} rejects still invalid rewrite without a third attempt" do
      narrator, attempts = narrator_with_replies(narrator_class, [ LONG_REPLY, "Too short." ])
      assert_equal FALLBACK, narrator.call
      assert_equal 2, attempts.length
      assert_empty narrator.supplied_content_context
    end

    {
      amount: "Your income is $999. Protect the basics first. Review the plan.",
      write: "I recorded the purchase. Protect the basics first. Review the plan.",
      markdown: "Protect the basics first.\n- Review required payments.\n- Choose a next step."
    }.each do |name, reply|
      test "#{narrator_class} reruns #{name} checks on its rewrite" do
        narrator, attempts = narrator_with_replies(narrator_class, [ LONG_REPLY, reply ])
        assert_equal FALLBACK, narrator.call
        assert_equal 2, attempts.length
      end
    end
  end

  test "challenge checks apply again to a rewritten reply" do
    narrator, attempts = narrator_with_replies(SavingsChallenge::Narrator,
      [ LONG_REPLY, "You are required to have a full budget. Protect the basics first. Review the plan." ])
    assert_equal FALLBACK, narrator.call
    assert_equal 2, attempts.length
  end

  test "BOG pattern narration repairs length through the shared path" do
    original = "Recorded purchases show a pattern. Pause before deciding. Check your basics first. Keep required payments covered. Compare your choices. Which change feels comfortable?"
    rewrite = "Recorded purchases show a pattern. Protect your basics first. Which change feels comfortable?"
    narrator, attempts = narrator_with_replies(SavingsChallenge::PatternsNarrator, [ original, rewrite ])
    narrator.instance_variable_get(:@answer_packet)[:verified_facts] = { merchants: [] }
    assert_equal rewrite, narrator.call
    assert_equal 2, attempts.length
    assert_includes attempts.last.fetch(:messages).last.fetch(:content), "3-4 sentences"
  end

  test "unsafe original is not sent for a length rewrite" do
    requests = []
    with_provider_replies([ "Your income is $999. Check the plan. Check the bills. Check the costs. What next?" ], requests) do
      responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
      refute_includes responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json), "$999"
    end
    assert_equal 1, requests.length
  end

  test "crisis response bypasses the coach length and never calls the provider" do
    config = JSON.parse(file_fixture("mia_coach_short_config.json").read)
    config["response_shape"]["min_sentences"] = 4
    persona = Mia::RuntimePersona.for_preview(config: config, persona_id: 42, draft_revision: 1)
    responder = Demo::MiaResponder.new(api_key: "test-key", persona: persona)
    responder.define_singleton_method(:openrouter_response) { |*| flunk "crisis called the provider" }
    assert_equal Mia::CrisisBoundary.response, responder.call("I want to die")
    assert_equal "deterministic_safety", responder.response_source
  end

  test "guarded hardship uses the writer while an unavailable crisis read is immediate" do
    message = "I cannot afford food this week"
    reply = "You need food too; going without meals is not something you should have to do. Please talk with your coach about getting food today. Does everyone have enough to eat today?"
    narrator, attempts = narrator_with_replies(HouseholdFinance::MiaNarrator, [ reply ], message: message)
    assert_equal reply, narrator.call
    assert_equal 1, attempts.length

    narrator, attempts = narrator_with_replies(HouseholdFinance::MiaNarrator, [], message: "I feel hopeless")
    assert_equal Mia::CrisisBoundary.response, narrator.call
    assert_empty attempts
  end

  test "crisis narration retains its safety reply even outside the coach sentence range" do
    config = JSON.parse(file_fixture("mia_coach_short_config.json").read)
    config["response_shape"]["min_sentences"] = 4
    persona = Mia::RuntimePersona.for_preview(config: config, persona_id: 42, draft_revision: 1)
    narrator, attempts = narrator_with_replies(HouseholdFinance::MiaNarrator, [ Mia::CrisisBoundary.response ], message: "I want to die")
    narrator.instance_variable_set(:@persona, persona)
    assert_equal Mia::CrisisBoundary.response, narrator.call
    assert_equal 0, attempts.length
  end

  test "character miss is rewritten once without truncating the next step" do
    long_reply = "#{'This feeling deserves a careful look, ' * 45}and you can pause. Protect your basics first. What is the purchase for?"
    narrator, attempts = narrator_with_replies(HouseholdFinance::MiaNarrator, [ long_reply, VALID_REPLY ])
    assert_equal VALID_REPLY, narrator.call
    assert_equal 2, attempts.length
    assert_equal long_reply, attempts.last.fetch(:messages)[-2].fetch(:content)
  end

  test "provider truncated output is rejected rather than rewritten or marked live" do
    requests = []
    with_provider_replies([ VALID_REPLY ], requests, finish_reason: "length") do
      responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
      refute_equal VALID_REPLY, responder.call(SAMPLE, context: Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json)
      assert_equal :reply_rejected, responder.fallback_reason
    end
    assert_equal 1, requests.length
  end

  test "shape logging reports only measured bounds for both misses" do
    logs = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logs)
    narrator, = narrator_with_replies(HouseholdFinance::MiaNarrator, [ LONG_REPLY, "Too short." ])
    assert_equal FALLBACK, narrator.call
    assert_equal 2, logs.string.scan("[Mia::ResponseShapeRewriter]").length
    assert_includes logs.string, "sentences=5 characters=#{LONG_REPLY.length} min_sentences=3 max_sentences=4 max_characters=1500"
    refute_includes logs.string, LONG_REPLY
    refute_includes logs.string, "Too short."
  ensure
    Rails.logger = original_logger
  end

  test "custom shape prompt wins over task length and preview notices stay in the screen" do
    narrator, = narrator_with_replies(HouseholdFinance::MiaNarrator, [])
    assert_includes narrator.send(:response_shape_instruction), "3-4 sentences total"
    refute_includes narrator.send(:response_shape_instruction), "exactly 3"
    responder = Demo::MiaResponder.new(api_key: "test-key", persona: @persona)
    instruction = responder.send(:response_shape_messages, Mia::PersonaPreviewer::PREVIEW_CONTEXT.to_json).sole.fetch(:content)
    assert_includes instruction, "3-4 sentences total"
    assert_includes instruction, "Do not repeat those notices"
  end

  private

  def narrator_with_replies(klass, replies, message: SAMPLE)
    attempts = []
    narrator = klass.new(user_message: message, persona: @persona, api_key: "test-key",
      answer_packet: { kind: "coaching", write_state: "no_write", fallback_response: FALLBACK })
    queue = replies.dup
    narrator.define_singleton_method(:openrouter_response) do
      attempts << send(:payload)
      raise "Unexpected third provider request" if queue.empty?
      queue.shift
    end
    [ narrator, attempts ]
  end

  def with_provider_replies(replies, requests, finish_reason: "stop")
    http = Object.new
    queue = replies.dup
    http.define_singleton_method(:request) do |request|
      requests << JSON.parse(request.body)
      raise "Unexpected extra provider request" if queue.empty?
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.body = JSON.generate(id: "gen-shape-#{requests.length}", model: "test-model-#{requests.length}",
        choices: [ { message: { content: queue.shift }, finish_reason: finish_reason } ])
      response
    end
    singleton = Net::HTTP.singleton_class
    original = singleton.instance_method(:start)
    singleton.define_method(:start) { |*_args, **_options, &block| block.call(http) }
    yield
  ensure
    singleton.define_method(:start, original)
  end
end
