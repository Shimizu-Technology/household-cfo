require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupTextEvidenceTest < ActiveSupport::TestCase
  include PersonaTestHelper
  setup do
    @coach = persona_user
    @persona = create_persona(creator: @coach, workspace: CoachWorkspaces::Provisioner.ensure_for!(@coach))
  end

  test "coaching and curriculum reject details absent from their own quote even if elsewhere in message" do
    %w[coaching.method coaching.philosophy coaching.principles coaching.do coaching.do_not curriculum.guidance curriculum.scripts curriculum.examples].each do |path|
      value = case path
      when "curriculum.guidance" then [ { "title" => "Basics", "content" => "Protect the basics first." } ]
      when "curriculum.scripts" then [ { "title" => "Basics", "steps" => [ "Protect the basics first." ] } ]
      when "curriculum.examples" then [ { "participant" => "How do I start?", "assistant" => "Protect the basics first." } ]
      when "coaching.principles", "coaching.do", "coaching.do_not" then [ "Protect the basics first." ]
      else "Protect the basics first."
      end
      op = operation(path, value, "I start with how they feel")
      error = assert_raises(Mia::PersonaSetup::OperationContract::ContractError, path) { contract.build([ op ]) }
      assert_equal "persona_setup_text_evidence", error.code
    end
  end

  test "phrase meaning needs its own supporting quote and crisis restriction stays mandatory" do
    phrase = { "text" => "Chelu, pump the brakes", "meaning" => "Suggest waiting 30 days.", "allowed_contexts" => [ "general" ], "prohibited_contexts" => [], "frequency" => "rare", "caution" => "" }
    op = operation("phrases", phrase, "Chelu, pump the brakes").merge("op" => "add_phrase")
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract.build([ op ]) }
    op["evidence_quote"] = "Chelu, pump the brakes and suggest waiting 30 days"
    phrase = contract.build([ op ]).dig(:after_state, "draft_config", "phrases").sole
    assert_includes phrase["prohibited_contexts"], "crisis"
  end

  test "normal descriptions retain aligned paraphrases and exact numbers without reversing negation" do
    assert Mia::PersonaSetup::TextEvidence.supports?('When someone is about to overspend I say "Chelu, pump the brakes" and suggest waiting 30 days.', "Said when someone is about to overspend, followed by a suggestion to wait 30 days.")
    assert Mia::PersonaSetup::TextEvidence.supports?("I start with how they feel, then one clear next step.", "Start with how the participant feels, then give one clear next step.")
    assert Mia::PersonaSetup::TextEvidence.supports?("I never tell people what to do with their money.", "Never tell participants what to do with their money.")
    refute Mia::PersonaSetup::TextEvidence.supports?("Do not suggest waiting 30 days.", "Suggest waiting 30 days.")
    refute Mia::PersonaSetup::TextEvidence.supports?("Suggest waiting 30 days.", "Suggest waiting 60 days.")
    op = operation("coaching.method", "Start with how the participant feels, then give one clear next step.", "I start with how they feel, then one clear next step")
    assert contract.build([ op ])
  end

  test "transcript drafts cannot bypass quote alignment and explicit creative philosophy remains allowed" do
    op = operation("coaching.method", "Invent a paid course.", "warm cousin").merge("source_basis" => "mia_drafted")
    transcript = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Propose a voice from this transcript: warm cousin")
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { transcript.build([ op ]) }
    creative = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Please suggest a coaching philosophy.")
    assert creative.build([ operation("coaching.philosophy", "Build confidence one decision at a time.", "").merge("source_basis" => "mia_drafted") ])
  end

  test "the recorded follow-up rejects its unsupported title and retains supported descriptions and phrase meaning" do
    recorded = JSON.parse(file_fixture("persona_setup/coach_followups_response.json").read)
    checker = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: recorded.fetch("message"))
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { checker.build(recorded.fetch("operations")) }
    corrected = recorded.fetch("operations").deep_dup
    corrected.find { |op| op["path"] == "curriculum.guidance" }.fetch("value").first["title"] = "When someone is about to overspend"
    result = checker.build(corrected)
    assert_equal 9, result.fetch(:operations).length
    phrase = result.dig(:after_state, "draft_config", "phrases").sole
    assert_equal "Chelu, pump the brakes", phrase.fetch("text")
    assert_includes phrase.fetch("meaning"), "30 days"
    assert_includes phrase.fetch("prohibited_contexts"), "crisis"
  end

  test "each clause preserves prohibitions including contractions and stop or avoid" do
    [
      [ "I can't tell people what to do.", "Tell people what to do." ],
      [ "I won't suggest waiting 30 days.", "Suggest waiting 30 days." ],
      [ "Don’t suggest waiting 30 days.", "Suggest waiting 30 days." ],
      [ "Stop spending on wants.", "Keep spending on wants." ],
      [ "Avoid shaming clients.", "Shame clients." ],
      [ "Don't shame them, tell them the numbers.", "Don't tell them the numbers." ],
      [ "Don't shame them and tell them the numbers.", "Don't tell them the numbers." ]
    ].each do |quote, claim|
      refute Mia::PersonaSetup::TextEvidence.supports?(quote, claim), "#{quote} must not support #{claim}"
    end
  end

  test "simple punctuation connectors and number equivalents stay supported without inventing a paraphrase" do
    [
      [ "I don’t shame", "Don't shame" ],
      [ "warm but firm", "Be warm and firm" ],
      [ "Offer two clear steps.", "Offer 2 clear steps." ],
      [ "I can't tell people what to do.", "Don't tell people what to do." ],
      [ "Stop spending on wants.", "Don't spend on wants." ],
      [ "Avoid shaming clients.", "Don't shame clients." ]
    ].each do |quote, claim|
      assert Mia::PersonaSetup::TextEvidence.supports?(quote, claim), "#{quote} should support #{claim}"
    end
    refute Mia::PersonaSetup::TextEvidence.supports?("warm but firm", "Be empathetic and decisive")
  end

  test "round two preserves negation and whole numbers 1" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Dont shame clients.", "Shame clients.")
  end

  test "round two preserves negation and whole numbers 2" do
    refute Mia::PersonaSetup::TextEvidence.supports?("cant shame clients.", "Shame clients.")
  end

  test "round two preserves negation and whole numbers 3" do
    refute Mia::PersonaSetup::TextEvidence.supports?("wont shame clients.", "Shame clients.")
  end

  test "round two preserves negation and whole numbers 4" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Clients aren’t shamed.", "Shame clients.")
  end

  test "round two preserves negation and whole numbers 5" do
    refute Mia::PersonaSetup::TextEvidence.supports?("We mustn’t shame people", "Shame people")
  end

  test "round two preserves negation and whole numbers 6" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Don’t tell people to stop spending.", "Tell people to stop spending.")
  end

  test "round two preserves negation and whole numbers 7" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Don’t shame people for spending.", "Don’t spend.")
  end

  test "round two preserves negation and whole numbers 8" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Instead of telling people what to do, ask questions.", "Tell people what to do.")
  end

  test "round two preserves negation and whole numbers 9" do
    refute Mia::PersonaSetup::TextEvidence.supports?("I refuse to shame people.", "Shame people.")
  end

  test "round two preserves negation and whole numbers 10" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Donʼt shame clients.", "Shame clients.")
  end

  test "round two preserves negation and whole numbers 11" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Save $1,500 a month.", "$500 a month.")
  end

  test "round two preserves negation and whole numbers 12" do
    refute Mia::PersonaSetup::TextEvidence.supports?("Spend 2.5 hours.", "5 hours.")
  end

  [
      [ "Only recommend waiting 30 days when bills are paid", "Recommend waiting 30 days" ],
      [ "Protect food before rent", "Protect rent before food" ],
      [ "Do not shame or blame clients", "Blame clients" ],
      [ "Don't stop spending", "Stop spending" ]
    ].each_with_index do |(quote, claim), index|
    test "review preserves restrictions relationships and coordinated negatives #{index}" do
      refute Mia::PersonaSetup::TextEvidence.supports?(quote, claim), "#{quote} must not support #{claim}"
    end
  end

  test "review preserves curriculum titles" do
    assert Mia::PersonaSetup::TextEvidence.supports?("Do not shame or blame clients", "Do not shame or blame clients")
    op = operation("curriculum.guidance", [ { "title" => "Wait 60 days", "content" => "Wait 30 days" } ], "Wait 30 days")
    checker = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "Wait 30 days")
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { checker.build([ op ]) }
  end

  private
  def operation(path, value, evidence)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "coach_quote", "evidence_quote" => evidence }
  end
  def contract
    Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "I start with how they feel, then one clear next step. I protect the basics first: roof, food, utilities, required payments. Chelu, pump the brakes and suggest waiting 30 days.")
  end
end
