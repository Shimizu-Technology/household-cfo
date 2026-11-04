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

  private
  def operation(path, value, evidence)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "coach_quote", "evidence_quote" => evidence }
  end
  def contract
    Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: "I start with how they feel, then one clear next step. I protect the basics first: roof, food, utilities, required payments. Chelu, pump the brakes and suggest waiting 30 days.")
  end
end
