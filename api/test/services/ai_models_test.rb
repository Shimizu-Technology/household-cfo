require "test_helper"

class AiModelsTest < ActiveSupport::TestCase
  test "text model prefers AI_MODEL, then the legacy OPENROUTER_MODEL, then the pinned default" do
    assert_equal "anthropic/claude-sonnet-5.5", AiModels.text({})
    assert_equal "google/gemini-2.5-flash", AiModels.text("OPENROUTER_MODEL" => "google/gemini-2.5-flash")
    assert_equal "anthropic/claude-sonnet-5.5",
      AiModels.text("AI_MODEL" => "anthropic/claude-sonnet-5.5", "OPENROUTER_MODEL" => "google/gemini-2.5-flash")
    assert_equal "google/gemini-2.5-flash", AiModels.text("AI_MODEL" => "  ", "OPENROUTER_MODEL" => " google/gemini-2.5-flash ")
  end

  test "retired per-task settings no longer change the text model" do
    env = {
      "OPENROUTER_MIA_MODEL" => "retired/narrator",
      "OPENROUTER_MIA_INTENT_MODEL" => "retired/intent",
      "OPENROUTER_EXTRACTION_MODEL" => "retired/extraction",
      "OPENROUTER_CONTENT_SOURCE_MODEL" => "retired/content",
      "OPENROUTER_PERSONA_SETUP_MODEL" => "retired/persona"
    }

    assert_equal AiModels::DEFAULT_TEXT_MODEL, AiModels.text(env)
  end

  test "transcription model prefers AI_TRANSCRIPTION_MODEL, then the legacy name, then Whisper" do
    assert_equal "openai/whisper-large-v3", AiModels.transcription({})
    assert_equal "openai/whisper-legacy", AiModels.transcription("OPENROUTER_TRANSCRIPTION_MODEL" => "openai/whisper-legacy")
    assert_equal "openai/whisper-new",
      AiModels.transcription("AI_TRANSCRIPTION_MODEL" => "openai/whisper-new", "OPENROUTER_TRANSCRIPTION_MODEL" => "openai/whisper-legacy")
    assert_equal "openai/whisper-large-v3", AiModels.transcription("MIA_TRANSCRIPTION_MODEL" => "retired/whisper")
  end

  test "only Claude models get light reasoning for chat calls" do
    assert_equal({ effort: "low" }, AiModels.chat_reasoning("anthropic/claude-sonnet-5.5"))
    assert_equal({ effort: "low" }, AiModels.chat_reasoning("~anthropic/claude-sonnet-latest"))
    assert_nil AiModels.chat_reasoning("google/gemini-2.5-flash")
    assert_nil AiModels.chat_reasoning(nil)
  end

  test "boot log names the configured models and warns about retired settings" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)

    AiModels.log_configuration(logger: logger, env: { "AI_MODEL" => "google/gemini-2.5-flash", "OPENROUTER_EXTRACTION_MODEL" => "google/gemini-2.5-flash" })

    assert_includes output.string, "[AiModels] text=google/gemini-2.5-flash transcription=openai/whisper-large-v3"
    assert_includes output.string, "ignoring retired model settings OPENROUTER_EXTRACTION_MODEL"
  end

  test "services default to the shared text and transcription models" do
    with_env("AI_MODEL" => "test/text-model", "AI_TRANSCRIPTION_MODEL" => "test/transcription-model") do
      assert_equal "test/text-model", HouseholdFinance::MiaIntentResolver.new(user_message: "hi", context: {}, api_key: nil).send(:model)
      assert_equal "test/text-model", HouseholdFinance::MiaNarrator.new(user_message: "hi", answer_packet: {}, api_key: nil).send(:model)
      assert_equal "test/text-model", Demo::MiaResponder.new(api_key: nil).requested_model_identifier
      assert_equal "test/text-model", FinancialDocuments::Extractor.new(api_key: nil).model
      assert_equal "test/text-model", ContentSources::CandidateProposer.new(api_key: nil).model
      assert_equal "test/text-model", Mia::PersonaSetup::ProposalResolver.new(api_key: nil).payload_for(context: {}, user_message: "hi").fetch(:model)
      assert_equal "test/transcription-model", HouseholdFinance::VoiceTranscriber.new(file: nil, api_key: nil).send(:model)
    end
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "sampling keeps tuned temperatures except for Claude" do
    assert_equal({ temperature: 0.45 }, AiModels.sampling("google/gemini-2.5-flash", 0.45))
    assert_equal({ temperature: 0 }, AiModels.sampling("exact/model", 0))
    assert_equal({}, AiModels.sampling("anthropic/claude-sonnet-5.5", 0.45))
    assert_equal({}, AiModels.sampling("~anthropic/claude-sonnet-latest", 0))
  end
end
