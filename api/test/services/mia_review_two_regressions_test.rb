# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/reply_guard_test_helper"

class MiaReviewTwoRegressionsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ReplyGuardTestHelper

  test "guard receives persona facts and complete packet on both delivery paths" do
    seen = []
    Mia::ReplyGuard.singleton_class.define_method(:call) { |**args| seen << args; Mia::ReplyGuard::Result.new([]) }
    narrator = narrator_for
    narrator.define_singleton_method(:openrouter_response) { "Check the funding first. Which account would cover it?" }
    narrator.call
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    responder.define_singleton_method(:openrouter_response) { |*, **_| "Check the funding first. Which account would cover it?" }
    responder.call("Should I buy a chair?", context: "{}")
    assert_equal 2, seen.size
    seen.each do |call|
      %w[Mrs. direct Household Chelu].each { |word| assert_includes call[:facts].to_json, word }
    end
    assert_includes seen.first[:facts].to_json, "packet_marker"
  end

  test "guard category gets one shared rewrite and new reply is guarded again" do
    guards = []
    Mia::ReplyGuard.singleton_class.define_method(:call) { |**args| guards << args[:reply]; Mia::ReplyGuard::Result.new(guards.one? ? [ "invented_fact" ] : []) }
    narrator = narrator_for
    replies = [ "The lender charges more than the sale saves. Which account would cover it?", "Check the funding first. Which account would cover it?" ]
    instructions = []
    narrator.define_singleton_method(:openrouter_response) { instructions << @response_shape_rewrite_messages; replies.shift }
    assert_includes narrator.call, "Check the funding first"
    assert_equal "live_model", narrator.response_source
    assert_equal 2, guards.size
    assert_includes instructions.last.to_json, "invented_fact"
  end

  test "shape and guard share one rewrite and provider failures never trigger generation" do
    [ false, true ].each do |provider_failure|
      Mia::ReplyGuard.singleton_class.define_method(:call) { |**_| Mia::ReplyGuard::Result.new([ provider_failure ? "provider_failure" : "invented_fact" ]) }
      replies = provider_failure ? [ "Check the funding first. Which account would cover it?" ] : [ "Check. " * 8 + "Which account would cover it?", "Check the funding first. Which account would cover it?" ]
      calls = 0
      narrator = narrator_for
      narrator.define_singleton_method(:openrouter_response) { calls += 1; replies.shift }
      narrator.call
      assert_equal(provider_failure ? 1 : 2, calls)
      assert_equal "deterministic_fallback", narrator.response_source
    end
  end

  test "demo guard uses shared rewrite with category instruction" do
    guards = 0
    Mia::ReplyGuard.singleton_class.define_method(:call) { |**_| guards += 1; Mia::ReplyGuard::Result.new(guards == 1 ? [ "invented_fact" ] : []) }
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    calls = []
    responder.define_singleton_method(:openrouter_response) do |*, **options|
      calls << options
      @response_source = "live_model"
      "Check the funding first. Which account would cover it?"
    end
    responder.call("Should I buy a chair?", context: "{}")
    assert_equal 2, calls.size
    assert_includes calls.last.to_json, "invented_fact"
    assert_equal "live_model", responder.response_source
  end

  test "role labels and paragraphs normalise before checks on both paths" do
    content = "  Mia: Check the funding first.\n\nWhich account would cover it?"
    narrator = narrator_for
    narrator.define_singleton_method(:openrouter_response) { content }
    assert_equal "#{prefix} Check the funding first. Which account would cover it?", narrator.call
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    assert_equal "Check the funding first. Which account would cover it?", responder.send(:sanitize_assistant_content, content, user_message: "Should I buy a chair?")
  end

  test "privacy card assumptions and unsupported cost comparisons have deterministic floors" do
    [ [ "The sponsor can review your credit card debts.", "privacy_claim" ], [ "That is a lot to put on a card.", "invented_fact" ], [ "Borrowing for a purchase like headphones means you would pay more than the discount saves.", "invented_fact" ] ].each do |reply, reason|
      guard = guard_for(reply)
      guard.define_singleton_method(:classify) { Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
      assert_includes guard.call.reasons, reason
    end
    [ "No purchase has been saved from this question.", "Which account or card would cover it?", "Card borrowing may cost interest." ].each do |reply|
      guard = guard_for(reply)
      guard.define_singleton_method(:classify) { Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
      assert guard.call.allowed?, reply
    end
  end

  test "transport gets one retry while malformed and semantic results do not" do
    guard = guard_for("Check the funding first.")
    calls = 0
    guard.define_singleton_method(:classify) { calls += 1; raise Net::ReadTimeout if calls == 1; Mia::ReplyGuard::FLAGS.index_with { false }.to_json }
    assert guard.call.allowed?
    assert_equal 2, calls
    [ "{}", Mia::ReplyGuard::FLAGS.index_with { |flag| flag == "invented_fact" }.to_json ].each do |raw|
      calls = 0
      guard.define_singleton_method(:classify) { calls += 1; raw }
      refute guard.call.allowed?
      assert_equal 1, calls
    end
  end

  test "safe preview fallback is shown sealed honestly and authorizes publication" do
    persona = create_persona(config: config)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: persona.created_by_user).call!
    responder = Object.new
    responder.define_singleton_method(:call) { |*, **_| "The actual safe reply." }
    responder.define_singleton_method(:response_source) { "deterministic_fallback" }
    responder.define_singleton_method(:fallback_reason) { :reply_rejected }
    responder.define_singleton_method(:rejection_reason) { :reply_guard }
    preview = Mia::PersonaPreviewer.new(persona: persona, sample_prompt: "Should I buy a chair?", candidate: candidate, responder: responder).call
    assert_equal "ready", preview[:status]
    assert_equal "deterministic_fallback", preview[:source]
    assert_equal "The actual safe reply.", preview[:sample_reply]
    assert_includes preview[:notice], "safe reply"
    assert_includes preview[:notice], "Teaching"
    evidence = Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: persona, actor: persona.created_by_user).call!(candidate: candidate, preview: preview)
    assert evidence.reload.integrity_valid?
    assert_equal "deterministic_fallback", evidence.response_source
    assert_equal "The actual safe reply.", evidence.output
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: persona.created_by_user).call!
    approval = Mia::PersonaRelease::RunApprover.new(run: run, actor: persona.created_by_user).call!(decision: "approved", expected_run_digest: run.run_digest)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: persona.created_by_user)
    compiled = publisher.preview!(expected_draft_revision: persona.draft_revision)
    Array(candidate.phrase_artifacts_snapshot).each do |artifact|
      Mia::PersonaRelease::AudienceAttester.new(persona: persona, actor: persona.created_by_user).call!(
        candidate_digest: candidate.manifest_digest, artifact_id: artifact.fetch("artifact_id"),
        artifact_fingerprint: artifact.fetch("fingerprint"), decision: "approved")
    end
    version = publisher.publish!(expected_preview_digest: compiled.fetch(:digest), expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil, expected_release_candidate_digest: candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest, expected_evaluation_approval_digest: approval.approval_digest,
      expected_behavioral_preview_digest: evidence.evidence_digest)
    assert_equal evidence, version.behavioral_preview_evidence
    assert_equal "deterministic_fallback", version.behavioral_preview_evidence.response_source
  end

  test "item clauses and plural head nouns produce natural labels and articles" do
    { "Could I buy $90 boots using my credit card?" => "boots", "Should I book $450 concert tickets on my card?" => "concert tickets", "Can I buy $120 headphones?" => "headphones", "Can I afford a $220 desk chair for working from home?" => "desk chair", "Could I buy a $400 sofa to replace the broken one?" => "sofa", "Can I buy a $50 bag paid with cash?" => "bag" }.each do |message, label|
      assert_equal label, HouseholdFinance::PurchaseQuestionText.item_label(message), message
    end
    { "boots" => "$90 boots", "concert tickets" => "$450 concert tickets", "headphones" => "$120 headphones", "desk chair for working from home" => "a $220 desk chair" }.each do |item, expected|
      assert_equal expected, HouseholdFinance::PurchaseQuestionText.priced_item(item, expected[/\$([\d,]+)/, 1].delete(",").to_i * 100)
    end
    { 1800 => "a", 800 => "an", 1100 => "a", 18 => "an" }.each do |amount, article|
      assert_equal "#{article} $#{amount.to_fs(:delimited)} chair", HouseholdFinance::PurchaseQuestionText.priced_item("chair", amount * 100)
    end
  end

  test "purchase prompt does not feed an assumed card or repeated canned question" do
    prompt = narrator_for.send(:purchase_contract)
    refute_includes prompt, "a lot to put on a card"
    assert_includes prompt, "Never assume a card"
    assert_includes prompt, "Vary the question"
  end

  test "generation disables provider fallback and has adequate output budget" do
    payload = narrator_for.send(:payload)
    assert_equal "anthropic/claude-sonnet-5.5", AiModels.text({})
    assert_equal "google/gemini-2.5-flash", AiModels.reply_guard({})
    assert_equal false, payload.dig(:provider, :allow_fallbacks)
    assert_operator payload.fetch(:max_tokens), :>=, AiModels.output_budget(AiModels.text, 1024)
  end

  test "review context parser accepts non JSON context without misreporting a provider outage" do
    responder = Demo::MiaResponder.new(api_key: "fake", persona: voice)
    responder.define_singleton_method(:openrouter_response) { |*, **_| @response_source = "live_model"; "Check the funding first. Which account would cover it?" }
    assert_equal "Check the funding first. Which account would cover it?", responder.call("Should I buy a chair?", context: "no household facts loaded")
    assert_equal "live_model", responder.response_source
  end

  test "review incomplete plan answer is never a fixed purchase comparison" do
    [ "Your 2027 plan is not set up yet. Which year do you mean?", "Your plan starts in December 2026. Which month are you considering?" ].each do |reference|
      narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I buy a chair?", api_key: "fake", persona: voice,
        answer_packet: { kind: "purchase_scenario", fallback_response: reference })
      narrator.define_singleton_method(:openrouter_response) { raise "must not generate" }
      assert_nil narrator.send(:purchase_prefix)
      assert_equal reference, narrator.call
    end
  end

  test "review household scoped purchase does not route to challenge" do
    assert_equal :household_read, Mia::HouseholdPlanRequest.classify("Can I afford a $300 stroller in our household budget?")
    assert_equal :challenge, Mia::HouseholdPlanRequest.classify("Can I afford a $300 stroller in my savings challenge?")
  end

  test "review debt payment wording is not a purchase while extra payment retains its scenario" do
    [ "Can I afford a $300 credit card payment?", "Can I afford a $300 payment on my credit card?" ].each do |message|
      assert HouseholdFinance::PurchaseQuestionText.debt_question?(message)
      resolver = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "")
      assert_nil resolver.send(:deterministic_scenario_type)
    end
    resolver = HouseholdFinance::MiaIntentResolver.new(user_message: "Can I afford a $300 extra credit card payment?", context: {}, api_key: "")
    assert_equal "extra_debt_payment", resolver.send(:deterministic_scenario_type)
    refute HouseholdFinance::PurchaseQuestionText.debt_question?("Can I buy a $300 stroller on my credit card?")
  end

  test "review ordinary broken goods and third person emotions do not become grief or hardship" do
    [ "My laptop died. Can I buy a $900 laptop?", "The car has engine failure. Can I buy a replacement?", "The baby is crying. Can I buy a stroller?", "What a shame, the sale ended." ].each do |message|
      refute Mia::SensitiveMoment.matches?(message), message
    end
    [ "My dad died last week.", "I am crying over the bills.", "I feel guilty about buying it.", "I feel like a failure.", "I hate myself for spending." ].each { |message| assert Mia::SensitiveMoment.matches?(message), message }
  end

  test "review overdraft charges remain spending but are not small purchases" do
    analyzer = SpendingPatterns::Analyzer.new(nil)
    assert analyzer.send(:bank_charge?, { merchant: "Overdraft Charge" })
    refute analyzer.send(:bank_charge?, { merchant: "Late Fee Cafe" })
  end

  private
  def config
    @config ||= persona_configuration.tap do |value|
      value["coaching"]["method"] = "Give the direct answer first and then ask one practical question."
      value["response_shape"].merge!("min_sentences" => 2, "max_sentences" => 4)
      value["phrases"] = [ persona_phrase_artifact({ text: "Chelu, pump the brakes." }) ]
    end
  end
  def voice = Mia::RuntimePersona.for_preview(config: config, persona_id: 1, draft_revision: 1)
  def prefix = "Your plan has $1,450 left, so a $220 chair would leave $1,230. That's a plan figure, not your bank balance."
  def narrator_for
    HouseholdFinance::MiaNarrator.new(user_message: "Can I buy a $220 chair?", api_key: "fake", persona: voice, answer_packet: { kind: "purchase_scenario", purchase_prefix: prefix, fallback_response: prefix, packet_marker: true })
  end
  def guard_for(reply)
    Mia::ReplyGuard.new(user_message: "Can I buy a $220 chair?", history: [], facts: {}, reply: reply, api_key: "fake")
  end
end
