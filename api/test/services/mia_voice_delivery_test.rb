require "test_helper"
require_relative "../support/persona_test_helper"

require_relative "../support/reply_guard_test_helper"

class MiaVoiceDeliveryTest < ActiveSupport::TestCase
  include ReplyGuardTestHelper
  include PersonaTestHelper

  test "guarded funding questions are not balance claims and statements still fail" do
    question = "When the statement is due, will the cash for this uniform be sitting in your account?"
    assert_nil Mia::NarrationClaims.rejection_reason(question, guard_covered: true)
    assert_equal :unsupported_balance_claim, Mia::NarrationClaims.rejection_reason(question)
    [ "The cash is in your account.", "You have money available to spend.", "The money is in your bank, right?" ].each do |reply|
      assert_equal :unsupported_balance_claim, Mia::NarrationClaims.rejection_reason(reply, guard_covered: true)
    end
  end

  test "cautious recommendations survive but approvals and false receipts do not" do
    [ "I recommend waiting. Which bill comes first?", "Chelu, pump the brakes. Hold off on the TV. What would cover it?", "That's a lot to put on a card. What could wait?" ].each do |reply|
      assert_nil Mia::NarrationClaims.rejection_reason(reply), reply
    end
    [ "Go ahead and buy it.", "You can buy it.", "There is plenty of room.", "I saved it.", "It is in your bank.", "Call 671-555-1234." ].each do |reply|
      assert Mia::NarrationClaims.rejection_reason(reply), reply
    end
  end

  test "a published voice can deliver three short purchase sentences with figures first" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Should I buy a $2,000 TV on my credit card? I don't have the money.",
      answer_packet: { kind: "purchase_scenario", fallback_response: "The $2,000 purchase would put the plan $550 short. That is a plan figure, not cash. You decide. Which account would cover it?" },
      api_key: "fake", persona: voice)
    narrator.define_singleton_method(:openrouter_response) { "What would you need to cover first?" }
    reply = narrator.call
    assert reply.start_with?("The $2,000 purchase would put the plan $550 short"), reply
    assert_includes reply, "Chelu, pump the brakes."
    refute_includes reply, "You decide."
  end

  test "income beside a purchase question uses a read only purchase amount without calling the model" do
    [ "I just got a raise to $5,200 a month. Can I afford a $600 phone?", "I make $5,200 a month now. Should I buy a $600 phone?", "My salary is now $5,200 monthly, could I get a $600 phone?" ].each do |message|
      resolver = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: { setup_status: { complete: true } }, api_key: "fake",
        transport: ->(*) { flunk "purchase should not need intent model" })
      result = resolver.call
      assert result&.read_only_plan?, message
      assert_equal "600", result.read_only_plan[:items].first[:amount], message
      assert_equal "none", result.action[:type]
    end
  end

  test "phrase context selects purchase caution and blocks hardship shame crisis and recent repetition" do
    message = "I keep ordering takeout with money I don't have."
    policy = Mia::LanguagePolicy.new(user_message: message, persona: voice)
    assert_includes policy.runtime_phrase_instruction, "Chelu, pump the brakes."
    [ "I cannot pay rent. Should I buy a TV?", "I feel ashamed about ordering takeout", "I feel stupid with money. Should I buy a TV?", "Everyone would be better off without me" ].each do |text|
      refute_includes Mia::LanguagePolicy.new(user_message: text, persona: voice).sanitize("Chelu, pump the brakes. Let's pause."), "Chelu"
    end
    refute_includes Mia::LanguagePolicy.new(user_message: message, history: [ { role: "assistant", content: "Chelu, pump the brakes." } ], persona: voice).runtime_phrase_instruction, "Chelu"
    refute_includes Mia::LanguagePolicy.new(user_message: message, persona: Mia::RuntimePersona.for_preview(config: persona_configuration, persona_id: 1, draft_revision: 1)).runtime_phrase_instruction, "Chelu"
  end

  test "card funding purchases take the deterministic comparison route" do
    [ "Should I buy a $2,000 TV on my credit card? I don't have the money.", "Could I buy a $150 pair of shoes on my credit card? I can't pay it off this month.", "Should I book a $700 weekend trip?" ].each do |message|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: { setup_status: { complete: true } }, api_key: "fake", transport: ->(*) { flunk "purchase comparison should not need the intent model" }).call
      assert result&.read_only_plan?, message
    end
  end

  test "purchase requests do not supply fallback figures to the model" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I buy a $300 stroller?", answer_packet: { kind: "purchase_scenario", fallback_response: "The $300 purchase would leave $1,150. Cash is unknown." })
    refute_includes narrator.send(:packet_json), "$1,150"
    refute_includes narrator.send(:packet_json), "verified_reference_answer"
    assert_includes narrator.send(:narrator_contract), "only the coaching portion"
  end

  test "safe four sentence coaching gets one rewrite inside the complete published range" do
    coaching = "Wait for now. A TV is a want, so holding off is the safer call. The sale may feel urgent, but the decision is yours. What money would cover it after bills?"
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Should I buy a $2,000 TV on my credit card? I don't have the money.", persona: voice, api_key: "fake", answer_packet: { kind: "purchase_scenario", fallback_response: "The $2,000 purchase would put the plan $550 short. That is a plan figure, not cash. You decide. Which account would cover it?" })
    attempts = 0
    narrator.define_singleton_method(:openrouter_response) do
      attempts += 1
      attempts == 1 ? coaching : "What money would cover it after bills?"
    end
    reply = narrator.call
    assert_equal 2, attempts
    assert_equal "live_model", narrator.response_source
    assert_includes reply, "Chelu, pump the brakes."
    assert Mia::ResponseShapePolicy.valid?(reply, persona: voice)
    [ "Buy it today.", "I saved the purchase.", "There is money in your account." ].each do |unsafe|
      narrator.define_singleton_method(:openrouter_response) { coaching.sub("The sale may feel urgent, but the decision is yours.", unsafe) }
      delivered = narrator.call
      refute_includes delivered, unsafe
      assert Mia::ResponseShapePolicy.valid?(delivered, persona: voice), delivered
    end
  end

  test "mixed income note is counted inside the whole purchase reply" do
    message = "I make $5,200 a month now. Should I buy a $600 phone?"
    narrator = HouseholdFinance::MiaNarrator.new(user_message: message, persona: voice, api_key: "fake", answer_packet: { kind: "purchase_scenario", fallback_response: "The $600 phone would leave $850 in the plan. That is a plan figure, not cash. You decide. What would cover it?" })
    narrator.define_singleton_method(:openrouter_response) { "We can review the income change separately. Which account would cover the phone?" }
    reply = narrator.call
    assert_includes reply, "review the income change separately"
    assert Mia::ResponseShapePolicy.valid?(reply, persona: voice), reply
    assert_equal "live_model", narrator.response_source
  end

  test "a refusal to claim affordability is cautious while later approvals still fail" do
    [ "I can't tell you it is affordable or funded.", "I cannot say you can afford this purchase.", "I can't confirm that the purchase fits." ].each do |reply|
      refute Demo::MiaResponder.unsupported_scenario_conclusion?(reply), reply
    end
    [ "I cannot say you can afford it, but you can afford the TV.", "I can't confirm that it is affordable. The purchase fits.", "You can afford it." ].each do |reply|
      assert Demo::MiaResponder.unsupported_scenario_conclusion?(reply), reply
    end
  end

  test "legacy phrase meanings and rare frequency remain usable without metadata changes" do
    config = persona_configuration
    config["phrases"] = [ persona_phrase_artifact({ text: "Chelu, pump the brakes.", meaning: "Chelu, pump the brakes.", frequency: "rare" }) ]
    persona = Mia::RuntimePersona.for_preview(config: config, persona_id: 1, draft_revision: 1)
    message = "I keep ordering takeout with money I don't have."
    assert_includes Mia::LanguagePolicy.new(user_message: message, persona: persona).runtime_phrase_instruction, "rare"
    history = [ { role: "assistant", content: "Chelu, pump the brakes before another order." }, { role: "assistant", content: "One step." }, { role: "assistant", content: "Protect essentials." } ]
    refute_includes Mia::LanguagePolicy.new(user_message: message, history: history, persona: persona).runtime_phrase_instruction, "Chelu"
  end

  test "the captured live stroller phrase is no longer eligible for an ordinary stroller question" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I afford a $300 stroller?", persona: voice, api_key: "fake", answer_packet: { kind: "purchase_scenario", fallback_response: "The $300 stroller would leave $1,150 in the plan. That is a plan figure, not cash. You decide. Which account would cover it?" })
    narrator.define_singleton_method(:openrouter_response) do
      "Hold off on deciding until you know where the money would come from, because I can't tell you it is affordable or funded. Chelu, pump the brakes. Is this stroller coming from money you have already set aside for it, or would it go on a card, and what bill or essential needs to be protected first?"
    end
    reply = narrator.call
    assert_equal "live_model", narrator.response_source
    refute_includes reply, "Chelu"
    assert Mia::ResponseShapePolicy.valid?(reply, persona: voice)
  end

  test "month packet preserves cents in coaching figures" do
    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(kind: "budget_question", fallback_response: "Spent $82.50", write_state: "no_write", month_answer: { spent_so_far_cents: 8250 }).call
    assert_equal 8250, packet.dig(:annual_plan_summary, :month_answer, :coaching_figures, :spent_so_far_cents)
  end

  private

  def voice
    config = persona_configuration
    config["response_shape"].merge!("min_sentences" => 3, "max_sentences" => 4)
    config["phrases"] = [ persona_phrase_artifact({ text: "Chelu, pump the brakes.", meaning: "Pause spending money you do not have", allowed_contexts: [ "general" ], prohibited_contexts: [ "crisis" ] }) ]
    Mia::RuntimePersona.for_preview(config: config, persona_id: 1, draft_revision: 1)
  end
end
