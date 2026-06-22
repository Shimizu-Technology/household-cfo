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
    assert_includes persona.disclaimer, "inside Household CFO powered by VERA"
  end

  test "unknown persona ids fall back to the configured default" do
    persona = Mia::Persona.find("missing_persona")

    assert_equal Mia::Persona::DEFAULT_ID, persona.id
    assert_equal "Mia", persona.name
  end

  test "demo household data resolves persona per call" do
    first_persona = Demo::HouseholdData.persona
    Mia::Persona.reset_cache!
    second_persona = Demo::HouseholdData.persona

    assert_equal first_persona.id, second_persona.id
    assert_not_same first_persona, second_persona
  end

  test "default persona includes screenshot-ready spending accountability line" do
    response = Mia::Persona.default.fallback_response(:spending)

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
    assert_includes response, "30-day list"
  end
end
