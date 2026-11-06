# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/reply_guard_test_helper"
require_relative "../support/savings_challenge_test_support"

class MiaReviewOneRegressionsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ReplyGuardTestHelper
  include SavingsChallengeTestSupport

  SENSITIVE = [ "My mom just passed away. Can I buy a $2,000 casket on my credit card?", "My son died last week and I keep ordering takeout.", "I can't buy food this week. Should I buy a $200 TV?", "I lost my job. Should I buy a TV?", "I can't make my minimum payment. Should I buy a phone?", "I hate myself for spending. Should I buy a TV?", "I feel like a loser. Should I buy a TV?", "I'm crying over my bills. Should I buy a TV?" ].freeze

  test "all sensitive disclosures get care before figures and no phrase or provider" do
    SENSITIVE.each do |message|
      narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", persona: voice,
        answer_packet: { kind: "purchase_scenario", fallback_response: reference })
      narrator.define_singleton_method(:openrouter_response) { "Chelu, pump the brakes. Which account would cover it?" }
      reply = narrator.call
      refute_match(/\$|Chelu|plan has/, reply, message)
      assert_includes reply, "coach", message
    end
  end

  test "server rejects ineligible and varied phrases before stripping them" do
    policy = Mia::LanguagePolicy.new(user_message: "Should I buy a TV on a credit card?", persona: voice)
    assert policy.phrase_rejection_reason("Chelu, slam the brakes you fool. What would cover it?")
    assert_nil policy.phrase_rejection_reason("Chelu, pump the brakes. What would cover it?")
    assert policy.phrase_rejection_reason("Chelu, pump the brakes. Chelu, pump the brakes. What would cover it?")
    [ "What's a sinking fund?", "I'm proud of myself.", *SENSITIVE ].each do |message|
      refute_includes Mia::LanguagePolicy.new(user_message: message, persona: voice).runtime_phrase_instruction, "Chelu", message
    end
  end

  test "real history blocks phrases after hardship and rare differs from sparing" do
    history = [ { role: "user", content: "I cannot pay rent this month." } ]
    policy = Mia::LanguagePolicy.new(user_message: "Should I buy a TV on a credit card?", persona: voice, history: history)
    refute_includes policy.runtime_phrase_instruction, "Chelu"
    history = [ { role: "assistant", content: "Chelu, pump the brakes." }, *4.times.map { { role: "assistant", content: "Check the funding." } } ]
    refute_includes Mia::LanguagePolicy.new(user_message: "Should I buy a TV on a credit card?", persona: voice(frequency: "rare"), history: history).runtime_phrase_instruction, "Chelu"
    assert_includes Mia::LanguagePolicy.new(user_message: "Should I buy a TV on a credit card?", persona: voice(frequency: "sparing"), history: history).runtime_phrase_instruction, "Chelu"
  end

  test "deterministic floor catches recommendations and refusal followed by approval" do
    [ "I recommend getting it.", "I recommend that you get it." ].each { |text| assert Mia::NarrationClaims.rejection_reason(text), text }
    [ "I can't say you can afford it, yet you clearly can.", "I can't say it works, though it clearly does.", "I can't confirm it fits, however you have room.", "I can't say it is affordable, except it obviously is." ].each do |text|
      assert Demo::MiaResponder.unsupported_scenario_conclusion?(text), text
    end
  end

  test "refusal cannot exempt the approval that follows a contrast" do
    [ "I can't say you can afford it, yet you clearly can.", "I can't say it works, though it clearly does.", "I can't confirm it fits, however you have room.", "I can't say it is affordable, except it obviously is." ].each do |text|
      assert Demo::MiaResponder.unsupported_scenario_conclusion?(text), text
    end
  end

  test "a general phrase still requires its meaning's stated moment" do
    [ "What's a sinking fund?", "I'm proud of myself." ].each do |message|
      refute_includes Mia::LanguagePolicy.new(user_message: message, persona: voice).runtime_phrase_instruction, "Chelu"
    end
  end

  test "a phrase variation is rejected rather than having chelu stripped" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Should I buy a TV on a credit card?", api_key: "fake", persona: voice,
      answer_packet: { kind: "purchase_scenario", fallback_response: "The $300 stroller would leave $1,150 in the plan. That is a plan figure, not cash." })
    narrator.define_singleton_method(:openrouter_response) { "Chelu, slam the brakes you fool. What would cover it?" }
    refute_includes narrator.call, "fool"
  end

  test "paying a card in full does not establish an uncovered payment" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Should I buy a $300 stroller on my credit card? I pay it in full every month.", api_key: "", persona: voice,
      answer_packet: { kind: "purchase_scenario", fallback_response: reference })
    refute_includes narrator.call, "cannot cover"
  end

  test "sensitive messages also preempt ongoing challenge goal and patterns threads" do
    [ "My son died last week. What should I do first?", "I feel like a loser. Can I get a smaller goal?" ].each do |message|
      assert SavingsChallenge::ChatTurn.protected_message?(message), message
    end
  end

  test "make rent ends meet and minimum payment are not income changes" do
    [ "I can't make rent. Should I buy a $600 phone?", "We're trying to make ends meet. Can I buy a $600 phone?", "I can't make my minimum payment. Should I buy a $600 phone?" ].each do |text|
      refute HouseholdFinance::PurchaseQuestionText.income_with_purchase?(text), text
    end
  end

  test "challenge nonpurchases and feelings never get a purchase prefix while real items do" do
    setup_savings_context
    with_savings_runtime do
      savings_enroll
      [ "I feel so guilty. I need to spend less.", "How can I spend less on takeout?", "Can I get a smaller goal?", "Can I get my streak back?", "Can I get help with my budget?", "Should I get a credit card?", "I went without meals. Should I buy a TV?" ].each do |message|
        coach = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: message)
        refute_includes coach.call, "no household plan", message
        assert_nil coach.purchase_prefix, message
      end
      coach = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: "Should I buy a $300 stroller on my credit card? I pay it in full every month.")
      reply = coach.call
      assert_includes reply, "stroller"
      refute_includes reply, "cannot cover"
      refute_includes reply, "the this"
    end
  end

  test "purchase fallback and generation honor real sentence budgets including figures only" do
    [ [ 1, 1 ], [ 1, 2 ], [ 2, 2 ], [ 2, 3 ], [ 3, 3 ], [ 5, 6 ] ].each do |minimum, maximum|
      persona = voice(minimum: minimum, maximum: maximum)
      narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I buy a $300 stroller?", persona: persona, api_key: "", answer_packet: { kind: "purchase_scenario", fallback_response: reference })
      reply = narrator.call
      assert Mia::ResponseShapePolicy.valid?(reply, persona: persona), "#{minimum}-#{maximum}: #{reply}"
      assert_includes reply, "$300"
      assert_includes reply, "$1,150"
      assert_includes reply, "bank balance"
      refute_includes reply, "?" if maximum <= 2
      refute_includes Mia::ResponseShapeRewriter.instruction(persona, fixed_prefix: reply), "at most 1 characters"
    end
    persona = voice(minimum: 1, maximum: 2, characters: 200)
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I buy a $300 stroller?", persona: persona, api_key: "", answer_packet: { kind: "purchase_scenario", fallback_response: reference })
    assert Mia::ResponseShapePolicy.valid?(narrator.call, persona: persona), narrator.call
  end

  test "labels preserve the item without repayment alternatives articles or pair of" do
    { "Should I buy a $150 pair of shoes?" => "shoes", "Can I buy a $300 stroller?" => "stroller", "Should I buy a $300 TV or pay off my credit card?" => "TV" }.each do |message, label|
      resolver = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "")
      assert_equal label, resolver.send(:deterministic_scenario_label, "purchase")
    end
  end

  test "debt questions reach intent model rather than the purchase shortcut" do
    [ "Should I spend $300 paying down my credit card?", "Should I get a $5,000 loan?" ].each do |message|
      calls = 0
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: { setup_status: { complete: true } }, api_key: "fake",
        transport: ->(*) { calls += 1; { intent: "coaching", confidence: 1, resolved_message: message, topic: { type: "debt" } }.to_json }).call
      assert_equal 1, calls, message
      refute_equal "purchase", result&.read_only_plan&.dig(:items, 0, :scenario_type), message
    end
  end

  test "preview recognizes a phrase used without its terminal punctuation" do
    owner = persona_user
    persona = create_persona(creator: owner, config: voice.send(:config))
    previewer = Mia::PersonaPreviewer.new(persona: persona, sample_prompt: "I keep ordering takeout with no money")
    assert_nil previewer.send(:phrase_notice, "Chelu, pump the brakes before the next order.")
  end

  test "fees and interest do not become buys and Late Fee Cafe remains a purchase" do
    analyzer = SpendingPatterns::Analyzer.new(nil)
    date = Date.new(2026, 10, 1)
    rows = [ "NSF", "Monthly Service Charge", "Foreign-transaction fee", "Interest Charge", "Late Fee Cafe", "Coffee", "Lunch" ].map.with_index do |merchant, index|
      { date: date + index, merchant: merchant, amount_cents: 100 }
    end
    clusters = analyzer.send(:clusters, rows)
    assert clusters.any?
    assert clusters.all? { |row| row[:purchase_count] == 3 && row[:total_cents] == 300 }, clusters.inspect
    rows.first[:kind] = "purchase"
    assert analyzer.send(:clusters, rows).any? { |row| row[:purchase_count] == 4 }
    rows[4][:kind] = "fee"
    assert analyzer.send(:clusters, rows).all? { |row| row[:purchase_count] <= 3 }
  end

  private

  def reference
    "Your November 2026 plan has $1,450 left, so a $300 stroller would leave $1,150 in the plan if it is extra spending. That's a plan figure, not your bank balance. You decide after protecting food, bills, and your emergency cushion. Which account would cover it?"
  end

  def voice(frequency: "sparing", minimum: 3, maximum: 4, characters: 1200)
    config = persona_configuration
    config["response_shape"].merge!("min_sentences" => minimum, "max_sentences" => maximum, "max_characters" => characters)
    config["phrases"] = [ persona_phrase_artifact({ text: "Chelu, pump the brakes.", meaning: "Pause an unfunded purchase", frequency: frequency }) ]
    Mia::RuntimePersona.for_preview(config: config, persona_id: 1, draft_revision: 1)
  end
end
