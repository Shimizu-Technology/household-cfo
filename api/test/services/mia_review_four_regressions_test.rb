# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/reply_guard_test_helper"

class MiaReviewFourRegressionsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ReplyGuardTestHelper

  test "guard owns ambiguous verdict and write wording on delivered purchase coaching" do
    outcomes = [ "No problem waiting while you check the timing. Which bill needs protecting?",
      "Before I recommend buying anything, check the funding. Which money would cover it?",
      "Nothing is saved or updated from asking. Which bill needs protecting?",
      "If the cash is saved for it, check required bills. Which bill needs protecting?" ].map do |reply|
      seen = []
      Mia::ReplyGuard.singleton_class.define_method(:call) { |**args| seen << args[:reply]; Mia::ReplyGuard::Result.new([]) }
      narrator = narrator_for(reply)
      delivered = narrator.call
      { source: narrator.response_source, reason: narrator.rejection_reason, includes_coaching: delivered.include?(reply), guarded_complete_reply: seen.last == delivered }
    end
    assert outcomes.all? { |row| row[:source] == "live_model" && row[:includes_coaching] && row[:guarded_complete_reply] }, outcomes.inspect
  end

  test "guard still blocks approval and write claims including rewrites and outages" do
    [ [ "You should buy it. Which account would cover it?", "purchase_approval" ],
      [ "I have updated your budget. Which bill needs protecting?", "action_claim" ],
      [ "No problem waiting while you check the timing. Which bill needs protecting?", "unavailable" ] ].each do |reply, flag|
      calls = 0
      Mia::ReplyGuard.singleton_class.define_method(:call) { |**_| calls += 1; Mia::ReplyGuard::Result.new([ flag ]) }
      narrator = narrator_for(reply)
      narrator.call
      assert_equal "deterministic_fallback", narrator.response_source
      assert_equal :reply_guard, narrator.rejection_reason
      assert_equal flag == "unavailable" ? 1 : 2, calls
    end
  end

  test "generic model coaching reaches guard before ambiguous verdict patterns reject it" do
    seen = []
    Mia::ReplyGuard.singleton_class.define_method(:call) { |**args| seen << args[:reply]; Mia::ReplyGuard::Result.new([]) }
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    reply = "No problem taking a pause. Check what starts the habit. What could you do before opening the shop?"
    responder.define_singleton_method(:openrouter_response) { |*, **_| @response_source = "live_model"; reply }
    assert_equal reply, responder.call("I keep ordering takeout after work.", context: "{}")
    assert_equal reply, seen.last
  end

  test "routine questions do not become invented personal routines" do
    [ "You use this at work; would you use it every day?", "You work from home. Do you use the chair every workday?" ].each do |reply|
      guard = Mia::ReplyGuard.new(user_message: "I work from home and use a chair at work.", history: [], facts: {}, reply: reply, api_key: "fake")
      guard.define_singleton_method(:classify) { Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
      assert guard.call.allowed?, reply
    end
  end

  test "short sentence prompt includes a concrete single question example" do
    assert_includes narrator_for("unused").send(:response_shape_instruction), "Which bill needs protecting?"
    assert_includes Demo::MiaResponder.new(api_key: "fake", persona: voice).send(:response_shape_messages, "{}").to_json, "Which bill needs protecting?"
  end

  test "unguarded claims still reject a purchase saved to the budget" do
    assert_equal :false_write_claim, Mia::NarrationClaims.rejection_reason("You've saved the purchase to your budget.")
  end

  test "hopeless habits keep the care reply" do
    message = "I keep spending money I don't have and I feel hopeless."
    responder = Demo::MiaResponder.new(api_key: "", persona: voice)
    reply = responder.call(message, context: "{}")
    refute_includes reply, "Pause before the next purchase"
  end

  test "hopeless fallback previews cannot authorize publication or carry a phrase notice" do
    message = "I keep spending money I don't have and I feel hopeless."
    responder = Object.new
    responder.define_singleton_method(:call) { |*, **_| "Talk with someone you trust." }
    responder.define_singleton_method(:response_source) { "deterministic_fallback" }
    persona = create_persona(config: persona_configuration)
    preview = Mia::PersonaPreviewer.new(persona: persona, sample_prompt: message, responder: responder).call
    assert_equal "safety_only", preview[:status]
    assert_nil preview[:phrase_notice]
  end

  test "plural minimums use deterministic care before purchase narration" do
    [ "I can't pay my minimums. Should I buy a $90 desk?", "I cannot pay my minimum payments. Should I buy a $90 desk?" ].each do |message|
      narrator = narrator_for("This must not reach the provider.")
      narrator.instance_variable_set(:@user_message, message)
      reply = narrator.call
      assert_equal "deterministic_safety", narrator.response_source
      assert_includes reply, "required payments"
      refute_match(/\$|Chelu/, reply)
    end
  end

  test "repeat visits without a purchase use a neutral question" do
    coach = HouseholdFinance::MiaCoachAnswerer.allocate
    coach.instance_variable_set(:@message, "I went to Ross again.")
    reply = coach.send(:repeated_pattern_answer)
    refute_includes reply, "decided to buy"
    assert_includes reply, "before you went"
  end

  test "card payment descriptions keep purchases eligible without hiding debt requests" do
    [ "Should I get a $300 stroller on my credit card?", "Can I take a $700 trip on my credit card?", "Should I buy a $300 TV on my credit card and pay off the balance next month?" ].each do |message|
      refute HouseholdFinance::PurchaseQuestionText.debt_question?(message), message
      resolver = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: { setup_status: { complete: true } }, api_key: "")
      result = resolver.call
      assert result&.read_only_plan?, message
      assert_equal "purchase", result.read_only_plan.dig(:items, 0, :scenario_type)
    end
    [ "Should I get a new credit card?", "Should I take a loan?", "How do I pay off my credit card?", "Should I buy a TV or pay off my credit card?" ].each do |message|
      assert HouseholdFinance::PurchaseQuestionText.debt_question?(message), message
    end
  end

  test "guard covered coaching still rejects contacts and urls before the guard" do
    [ "Email coach@example.invalid. Which bill needs protecting?", "Visit https://example.invalid. Which bill needs protecting?" ].each do |reply|
      narrator = narrator_for(reply)
      narrator.call
      assert_equal "deterministic_fallback", narrator.response_source
      assert_includes [ :invented_email, :invented_url ], narrator.rejection_reason
    end
  end

  test "purchase articles cannot strip part of a pronoun into an invented item" do
    coach = HouseholdFinance::MiaCoachAnswerer.allocate
    coach.instance_variable_set(:@message, "The shoes are $90. Can I get them?")
    assert_nil coach.send(:purchase_item)
    coach.instance_variable_set(:@message, "Can I get the table?")
    assert_equal "table", coach.send(:purchase_item)
  end

  private

  def voice
    @voice ||= Mia::RuntimePersona.for_preview(config: persona_configuration, persona_id: 1, draft_revision: 1)
  end

  def narrator_for(reply)
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Could I buy a $90 desk?", api_key: "fake", persona: voice,
      answer_packet: { kind: "purchase_scenario", write_state: "no_write", fallback_response: "This month’s plan has $1,450 left, so a $90 desk would leave $1,360. That's a plan figure, not your bank balance. Which bill needs protecting?" })
    narrator.define_singleton_method(:openrouter_response) { reply }
    narrator
  end
end
