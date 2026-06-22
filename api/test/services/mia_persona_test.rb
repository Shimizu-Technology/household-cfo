require "test_helper"

class MiaPersonaTest < ActiveSupport::TestCase
  test "default persona exposes layered coaching and culture rules" do
    persona = Mia::Persona.default
    prompt = persona.system_prompt

    assert_equal "Mia", persona.name
    assert_equal "AI financial coach", persona.role
    assert_includes persona.voice_summary, "culturally grounded"
    assert_includes prompt, "Cognitive behavioral coaching"
    assert_includes prompt, "validate before coaching"
    assert_includes prompt, "young Chamorro woman"
    assert_includes prompt, "Phrase library"
    assert_includes prompt, "Do not"
  end

  test "default persona includes screenshot-ready spending accountability line" do
    response = Mia::Persona.default.fallback_response(:spending)

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
    assert_includes response, "30-day list"
  end
end
