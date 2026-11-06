# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaSetupVoiceUnderstandingTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @coach).call
    @persona = create_persona(creator: @coach, workspace: @workspace)
  end

  test "recorded live warm auntie response accepts the coach's honest tone" do
    raw = JSON.parse(file_fixture("persona_setup/warm_auntie_response.json").read)
    result = contract("Sound like a warm auntie who is honest with people.").build(raw.fetch("operations"))
    assert_includes result.dig(:after_state, "draft_config", "voice", "tone_traits"), "candid"
  end

  test "varied recorded live descriptions retain all supported voice and phrase suggestions" do
    examples = JSON.parse(file_fixture("persona_setup/voice_descriptions_responses.json").read)
    examples.each do |example|
      state = example["evidence_state"] || @persona.draft_config
      operations = Mia::PersonaSetup::PhraseSuggestions.new(message: example["message"], phrases: state["phrases"]).call(example["operations"])
      result = Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: example["message"],
        previous_operations: example["previous_operations"], evidence_state: state).build_partial(operations)
      assert_empty result[:dropped], example["message"]
      assert result[:operations].any?, example["message"]
    end
  end

  test "familiar comparisons preserve exact self description without deriving a regional voice" do
    [ "Sound like a warm auntie who is honest with people.", "Talk like a patient older cousin.", "I speak like a kind, patient older cousin.", "Reply like a kind friend." ].each do |message|
      result = contract(message).build([ set("coaching.do", [ message ], message) ])
      assert_includes result.dig(:after_state, "draft_config", "coaching", "do"), message
    end
    [ "Sound like a Chamorro auntie.", "Talk like a warm auntie from Guam.", "Sound like a warm auntie, with an island accent.", "Sound like a warm auntie. Guamanians are careless with money." ].each do |message|
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError, message) do
        contract(message).build([ set("coaching.do", [ message ], message) ])
      end
    end
  end

  test "plain words and explaining financial terms support communication choices" do
    message = "I explain financial terms briefly and use plain words."
    current = @persona.draft_config.dig("voice", "language_style")
    result = contract(message).build([ set("voice.language_style", current + [ "Explain unfamiliar financial terms briefly." ], message) ])
    assert_includes result.dig(:after_state, "draft_config", "voice", "language_style"), "Explain unfamiliar financial terms briefly."
  end

  test "quote punctuation repair keeps supplied meaning use and frequency" do
    message = 'When someone is about to spend money they do not have, I say "Chelu, pump the brakes." Use it often in that situation.'
    meaning = "When someone is about to spend money they do not have"
    raw = phrase("Chelu, pump the brakes", meaning, message)
    repaired = Mia::PersonaSetup::PhraseSuggestions.new(message:).call([ raw ])
    saved = contract(message).build(repaired).dig(:after_state, "draft_config", "phrases").sole
    assert_equal "Chelu, pump the brakes.", saved["text"]
    assert_equal meaning, saved["meaning"]
    assert_equal "as_needed", saved["frequency"]
    assert_equal [ "crisis" ], saved["prohibited_contexts"]
    serialized = Mia::PersonaSetup::Serializer.allocate
    proposal = Struct.new(:operations, :before_state, :after_state).new(repaired, Mia::PersonaDraftUpdater.state_for(@persona), { "draft_config" => @persona.draft_config })
    change = serialized.send(:grouped_changes, proposal).sole[:changes].sole
    assert_equal meaning, change.dig(:phrase, "meaning")
  end

  test "an embellished meaning falls back to the complete coach sentence without losing when to use it" do
    message = 'When someone is about to overspend I say "Chelu, pump the brakes." and suggest waiting 30 days.'
    repaired = Mia::PersonaSetup::PhraseSuggestions.new(message:).call([ phrase("Chelu, pump the brakes", "An invented charming island expression.", "Chelu, pump the brakes") ])
    saved = contract(message).build(repaired).dig(:after_state, "draft_config", "phrases").sole
    assert_equal message, saved["meaning"]
    refute_includes saved["meaning"], "invented"
  end

  test "recovered meaning comes only from the authorized coach quote" do
    message = "My client says \"Pause\" when rent is due.\nCoach: I say \"Pause\" when someone is about to overspend."
    repaired = Mia::PersonaSetup::PhraseSuggestions.new(message:).call([ phrase("Pause", "An invented explanation", "Pause") ])
    saved = contract(message).build(repaired).dig(:after_state, "draft_config", "phrases").sole
    assert_equal 'I say "Pause" when someone is about to overspend.', saved["meaning"]
    refute_includes saved["meaning"], "rent"
  end

  test "a voice preamble cannot disguise a same-line client speaker as coach prose" do
    [ "Client", "Participant #2", "Maria", "Guest / visitor" ].each do |speaker|
      message = %(Sound like a warm auntie. #{speaker}: I say "Rent comes first")
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message:).exact_quote("Rent comes first"), speaker
      assert_raises(Mia::PersonaSetup::OperationContract::ContractError) do
        contract(message).build([ phrase("Rent comes first", "Rent comes first", "Rent comes first") ])
      end
    end
  end

  test "a follow-up updates saved phrase use and keeps its meaning identity and reviewed publication" do
    original = persona_phrase_artifact({ "text" => "Chelu, pump the brakes.", "meaning" => "When someone is about to spend money they do not have" }, source_user_id: @coach.id)
    @persona.update!(draft_config: @persona.draft_config.deep_merge("phrases" => [ original ]))
    message = 'Please use my saying "Chelu, pump the brakes." often.'
    raw = phrase(original["text"], original["meaning"], message)
    operations = [ raw ]
    result = contract(message).build(operations)
    saved = result.dig(:after_state, "draft_config", "phrases").sole
    assert_equal original["artifact_id"], saved["artifact_id"]
    assert_equal original["meaning"], saved["meaning"]
    assert_equal "as_needed", saved["frequency"]
    refute_equal original["fingerprint"], saved["fingerprint"]
    assert_equal "rare", @persona.reload.draft_config["phrases"].sole["frequency"]
    @persona.update!(draft_config: result.dig(:after_state, "draft_config"))
    version = publish_persona(@persona, actor: @coach)
    assert_equal saved, version.config["phrases"].sole
  end

  test "expanded explicit authoring commands still reject bans third-party words and crisis" do
    [ 'Also say: "Small wins count, chelu."', 'Sound like a warm auntie who is honest with people. Also say: "Small wins count, chelu."', 'Please use my saying "Small wins count, chelu." often.' ].each do |message|
      assert_equal "Small wins count, chelu.", Mia::PersonaSetup::PhraseSuggestions.new(message:).exact_quote("Small wins count, chelu")
    end
    [ 'Do not use my saying "Small wins count, chelu."', 'My client says "Small wins count, chelu."', 'Client: Also say: "Small wins count, chelu."', 'Avoid saying "Small wins count, chelu."' ].each do |message|
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message:).exact_quote("Small wins count, chelu"), message
      assert_empty Mia::PersonaSetup::PhraseSuggestions.new(message:).call([])
    end
    message = 'I say "Small wins count, chelu."'
    unsafe = phrase("Small wins count, chelu.", "Small wins count, chelu.", message)
    unsafe["value"]["allowed_contexts"] = [ "crisis" ]
    assert_raises(Mia::PersonaSetup::OperationContract::ContractError) { contract(message).build([ unsafe ]) }
  end

  private

  def contract(message)
    Mia::PersonaSetup::OperationContract.new(actor: @coach, persona: @persona, user_message: message)
  end

  def set(path, value, evidence)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => "coach_quote", "evidence_quote" => evidence }
  end

  def phrase(text, meaning, evidence)
    { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => evidence,
      "value" => { "text" => text, "meaning" => meaning, "allowed_contexts" => [ "general" ], "prohibited_contexts" => [ "crisis" ], "frequency" => "as_needed", "caution" => "" } }
  end
end
