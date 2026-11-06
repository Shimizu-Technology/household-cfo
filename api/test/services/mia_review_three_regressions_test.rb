# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/reply_guard_test_helper"

class MiaReviewThreeRegressionsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ReplyGuardTestHelper

  test "purchase facts consume one honest sentence with the real remaining budget" do
    narrator = narrator_for
    prefix = narrator.send(:purchase_prefix)
    assert_equal "This month’s plan has $1,450 left, so $90 boots would leave $1,360, and that's a plan figure, not your bank balance.", prefix
    assert_equal 1, Mia::ResponseShapePolicy.new(prefix, persona: voice).sentence_count
    assert_equal 2..3, narrator.send(:purchase_sentence_range)
    refute_includes prefix, ";"
  end

  test "server inserts exact eligible phrase before coaching and guards the whole answer" do
    seen = []
    Mia::ReplyGuard.singleton_class.define_method(:call) { |**args| seen << args[:reply]; Mia::ReplyGuard::Result.new([]) }
    narrator = narrator_for(message: "Can I buy $90 boots? I don't have the money.")
    narrator.define_singleton_method(:openrouter_response) { "Hold off while you work out the funding. Which bill would need protecting?" }
    reply = narrator.call
    assert_equal "live_model", narrator.response_source
    assert_includes reply, "bank balance. Chelu, pump the brakes. Hold off"
    assert_equal 1, reply.scan("Chelu, pump the brakes.").size
    assert_equal reply, seen.last
    assert_includes narrator.send(:payload).to_json, "don't repeat or paraphrase it"
    assert_equal 1..2, narrator.send(:purchase_sentence_range)
  end

  test "model cannot write an exact server phrase or a variant on either path" do
    [ "Chelu, pump the brakes.", "Chelu, pump the brakes before the next one." ].each do |phrase|
      narrator = narrator_for(message: "Can I buy $90 boots? I don't have the money.")
      narrator.define_singleton_method(:openrouter_response) { "#{phrase} Which bill needs protecting?" }
      narrator.call
      assert_equal "deterministic_fallback", narrator.response_source
      responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
      assert_nil responder.send(:sanitize_assistant_content, "#{phrase} Which bill needs protecting?", user_message: "I keep buying things online with money I don't have.")
    end
  end

  test "habit server phrase consumes its own sentence and respects sensitivity and frequency" do
    message = "I keep buying little things online with money I don't have."
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    responder.define_singleton_method(:openrouter_response) { |*, **_| @response_source = "live_model"; "You're noticing a pattern. Pause before opening the shop. What usually starts an order?" }
    reply = responder.call(message, context: "{}")
    assert_equal "Chelu, pump the brakes. You're noticing a pattern. Pause before opening the shop. What usually starts an order?", reply
    narrator = narrator_for(message: "Can I buy $90 boots? I saved cash for them.")
    refute_includes narrator.call, "Chelu"
    policy = Mia::LanguagePolicy.new(user_message: "I keep buying things and I feel ashamed.", persona: voice)
    assert_nil policy.server_phrase
    policy = Mia::LanguagePolicy.new(user_message: message, history: [ { role: "assistant", content: "Chelu, pump the brakes." } ], persona: voice)
    assert_nil policy.server_phrase
  end

  test "participant saved cash acknowledgment is not Mia claiming a write" do
    [ "You saved the cash for this sewing machine. Which bills need protecting?", "Since you've saved the cash, check whether any bills need it.", "You have already saved for it, so check the timing." ].each do |text|
      assert_nil Mia::NarrationClaims.rejection_reason(text), text
    end
    [ "I saved the purchase.", "We have updated your budget.", "Your purchase has been recorded.", "The plan was updated." ].each do |text|
      assert_equal :false_write_claim, Mia::NarrationClaims.rejection_reason(text), text
    end
  end

  test "neutral funding and affordability questions pass the floor without an approval" do
    [ "What would you check before deciding whether you can afford it?", "Check whether it fits your budget before deciding.", "Since you've set the money aside, that part's covered; check it doesn't touch bills." ].each do |reply|
      refute Demo::MiaResponder.unsupported_scenario_conclusion?(reply), reply
    end
    [ "It fits your budget, so buy it.", "If you have the cash, go ahead.", "I cannot say you can afford it, but it works." ].each do |reply|
      assert Mia::NarrationClaims.rejection_reason(reply) || Demo::MiaResponder.unsupported_scenario_conclusion?(reply), reply
    end
    prompt = Mia::ReplyGuard::SYSTEM_PROMPT
    assert_includes prompt, "Neutral next steps"
    assert_includes prompt, "participant's own saving"
    assert_includes prompt, "hard week"
  end

  test "unsupported personal routines have a floor without rejecting questions or stated routines" do
    message = "Can I afford a desk chair for working from home?"
    guard = Mia::ReplyGuard.new(user_message: message, history: [], facts: {}, reply: "A chair you sit in every workday is a real need.", api_key: "fake")
    guard.define_singleton_method(:classify) { Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
    assert_includes guard.call.reasons, "invented_fact"
    [ [ message, "Would you use it every workday?" ], [ "I sit in this chair every workday.", "A chair you sit in every workday deserves thought." ] ].each do |user, reply|
      guard = Mia::ReplyGuard.new(user_message: user, history: [], facts: {}, reply: reply, api_key: "fake")
      guard.define_singleton_method(:classify) { Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
      assert guard.call.allowed?
    end
  end

  test "price references do not erase a stated price but true ambiguity still clarifies" do
    [ "Can I buy $600 replacement tires? The shop quoted that price, but I would have to borrow.", "Could I order a $400 oven? That is the price the store gave me." ].each do |message|
      refute HouseholdFinance::PurchaseQuestionText.for_comparison(message).needs_clarification
    end
    [ "Can I buy $600 tires? The price is negotiable.", "Can I buy $600 tires? The shop quoted $700 instead." ].each do |message|
      assert HouseholdFinance::PurchaseQuestionText.for_comparison(message).needs_clarification
    end
  end

  test "fallbacks answer purchases and online habits without system topic menus" do
    responder = Demo::MiaResponder.new(api_key: "", persona: voice)
    reply = responder.call("Should I buy a $100 treat on my credit card? I don't have the money right now.", context: "{}")
    refute_includes reply, "Ask me about"
    general = responder.call("What should I look at next?", context: "{}")
    refute_includes general, "Ask me about"
    assert_includes reply, "funding"
    coach = HouseholdFinance::MiaCoachAnswerer.allocate
    coach.instance_variable_set(:@message, "I keep buying little things online with money I don't have.")
    reply = coach.send(:repeated_pattern_answer)
    refute_includes reply, "trip"
    refute_includes reply, "go again"
    assert_includes reply, "purchase"
  end

  test "preview exercises the same model reply path with server phrase and ordinary hard week" do
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    responder.define_singleton_method(:openrouter_response) do |*, **_|
      @response_source = "live_model"
      @concrete_model_identifier = "test-sonnet"
      @provider_request_id = "gen-preview"
      "Hold off until you know how to cover it. Which bill needs protecting?"
    end
    persona = create_persona(config: config)
    preview = Mia::PersonaPreviewer.new(persona: persona, sample_prompt: "Should I buy a $100 treat on my credit card? I don't have the money right now.", responder: responder).call
    assert_equal "live_model", preview[:source]
    assert_includes preview[:sample_reply], "Chelu, pump the brakes. Hold off"
  end

  test "short sentence instruction and total character budget include server wording" do
    prompt = narrator_for.send(:purchase_contract)
    assert_includes prompt, "at most 30 words"
    assert_includes prompt, "one question"
    policy = Mia::ResponseShapeRewriter.instruction(voice, fixed_prefix: "A fixed sentence.")
    assert_includes policy, "1482 characters"
  end

  test "saving calibration is scoped to participant reports and leaves unsafe eval prompt identical" do
    reported = Mia::ReplyGuard.new(user_message: "Could I buy a mixer? I've saved the cash for it.", history: [], facts: {}, reply: "You saved the cash. Check required bills.", api_key: "fake")
    assert_includes reported.send(:classification_prompt), "saving step is covered"
    [ "Should I buy a $2,000 TV on my credit card? I don't have the money but it is on sale.", "Can I buy a mixer? I have not saved for it.", "My sister saved cash." ].each do |message|
      guard = Mia::ReplyGuard.new(user_message: message, history: [], facts: {}, reply: "Go ahead.", api_key: "fake")
      assert_equal Mia::ReplyGuard::SYSTEM_PROMPT, guard.send(:classification_prompt)
    end
  end

  test "online habit fallback names the purchase rather than a trip" do
    coach = HouseholdFinance::MiaCoachAnswerer.allocate
    coach.instance_variable_set(:@message, "I keep buying little things online with money I don't have.")
    reply = coach.send(:repeated_pattern_answer)
    assert_includes reply, "next purchase"
    refute_includes reply, "trip"
  end

  test "phrase suppression does not promise an omitted phrase to the model" do
    policy = Mia::LanguagePolicy.new(user_message: "I keep buying online with money I don't have.", persona: voice)
    assert_includes policy.server_phrase_instruction(include_phrase: false), "No coach phrase"
    refute_includes policy.server_phrase_instruction(include_phrase: false), "will be said"
  end

  test "phrase free fallback reclaims the omitted phrase sentence" do
    config["response_shape"].merge!("min_sentences" => 3, "max_sentences" => 3)
    narrator = narrator_for(message: "Can I buy $90 boots? I don't have the money.")
    narrator.define_singleton_method(:openrouter_response) { nil }
    reply = narrator.call
    assert_equal "deterministic_fallback", narrator.response_source
    refute_includes reply, "Chelu"
    assert Mia::ResponseShapePolicy.valid?(reply, persona: voice), reply
  end

  test "challenge no plan prefix reaches the model on both funded and unfunded questions" do
    [ "Can I buy a $95 backpack? I saved cash for it.", "Can I buy a $360 console? I don't have the money." ].each do |message|
      prefix = "There is no household plan in this challenge to compare a purchase against, and I cannot verify the cash or card payments you would need."
      narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", persona: voice,
        answer_packet: { kind: "purchase_scenario", purchase_prefix: prefix, fallback_response: prefix })
      narrator.define_singleton_method(:openrouter_response) { "Check required bills first. Which money would cover it?" }
      assert_equal "live_model", narrator.tap(&:call).response_source
    end
  end

  test "saved cash nouns and funding questions never imply a completed app write" do
    [ "Which account or saved cash would cover it?", "Before you buy, check essentials without touching that saved cash.", "Money you saved for it still needs a bill check." ].each do |reply|
      assert_nil Mia::NarrationClaims.rejection_reason(reply), reply
    end
    [ "I saved this purchase.", "This purchase was saved.", "Your plan has been updated.", "We recorded the spending." ].each do |reply|
      assert_equal :false_write_claim, Mia::NarrationClaims.rejection_reason(reply), reply
    end
  end

  test "timing questions do not become permission to purchase" do
    [ "What is the latest date you can buy the tickets?", "If you keep this on the list, what date do you need to book by?" ].each do |reply|
      assert_nil Mia::NarrationClaims.rejection_reason(reply), reply
    end
    [ "You can buy it.", "Go ahead and buy it.", "If you want it, you should buy it.", "You need to book it today." ].each do |reply|
      assert_equal :purchase_verdict, Mia::NarrationClaims.rejection_reason(reply), reply
    end
  end

  test "unfunded want phrase does not label a stated replacement as a want" do
    policy = Mia::LanguagePolicy.new(user_message: "Could I buy $580 replacement tires? I would have to borrow.", persona: voice)
    assert_nil policy.server_phrase
  end

  private
  def config
    @config ||= persona_configuration.tap do |value|
      value["response_shape"].merge!("min_sentences" => 3, "max_sentences" => 4)
      value["phrases"] = [ persona_phrase_artifact({ text: "Chelu, pump the brakes.", meaning: "Pause when someone is about to spend money they do not have, or use a card for an unfunded want.", allowed_contexts: [ "general" ], frequency: "as_needed" }) ]
    end
  end
  def voice = Mia::RuntimePersona.for_preview(config: config, persona_id: 1, draft_revision: 1)
  def narrator_for(message: "Could I buy $90 boots using my credit card? I pay it in full every month.")
    HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", persona: voice,
      answer_packet: { kind: "purchase_scenario", fallback_response: "This month’s plan has $1,450 left, so $90 boots would leave $1,360. That's a plan figure, not your bank balance. Which account would cover it?" })
  end
end
