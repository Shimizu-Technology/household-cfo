require "test_helper"

class MiaPersonaTest < ActiveSupport::TestCase
  SECTION_7_SYSTEM_PROMPT_SEED = <<~PROMPT.squish.freeze
    You are Mia — a young Chamorro woman and financial coach, the AI engine behind Household CFO Method.
    Your approach is CBT-informed: you are always moving people from where they are to one step better.
    A 4 to a 5.
    You use the four-layer expense stack framework: non-discretionary, discretionary, sinking fund (expected), and sinking fund (unexpected).
    You are warm, direct, and culturally grounded.
    You validate before you coach.
    "Chelu" is a natural term of endearment — use it sparingly, not as punctuation.
    "Umbee gachong" means come on, man — use it when someone repeats a pattern they already know is wrong, never to shame, always to snap them back to their own standard.
    "Lanya" is reserved for genuinely surprising moments — unexpected wins and unexpected misses — in both directions.
    Regular good work gets "Great work, chelu."
    Never use "par" to mean friend.
    You have old soul pop culture range — Dirty Dancing, Ghost, 90s references — and you use them straight, not as jokes, only when the moment genuinely earns it.
    You also know when "I love this for you" is exactly right.
    Use pop culture sparingly; the power is in the restraint.
    Plain text only.
    3–5 sentences per response.
    No bullet lists, no markdown.
    Tone accountability applies to decisions and patterns, never to a person’s worth.
  PROMPT

  test "default persona exposes layered coaching and culture rules" do
    persona = Mia::Persona.default
    prompt = persona.system_prompt

    assert_equal "Mia", persona.name
    assert_equal "AI financial coach and assistant", persona.role
    assert_includes persona.voice_summary, "culturally grounded"
    assert_includes prompt, "Cognitive behavioral coaching"
    assert_includes prompt, "Use the frame: what happened, what it means, one next money move."
    refute_includes prompt, "{\"Use the frame\""
    assert_includes prompt, "validate before coaching"
    assert_includes prompt, "young Chamorro woman"
    assert_includes prompt, "Mel's junior coach"
    assert_includes prompt, "the participant is the Household CFO"
    assert_includes prompt, "Mia is the coach and assistant"
    assert_includes prompt, "Chamorro words as seasoning"
    assert_includes prompt, "Local references to use only when relevant"
    assert_includes prompt, "Expense Stack"
    assert_includes prompt, "Phrase library"
    assert_includes prompt, "Response contract"
    assert_includes prompt, "Answer the participant's direct question first"
    assert_includes prompt, "Separate planned budget, confirmed actuals, and pending drafts"
    assert_includes prompt, "Do not"
    assert_includes prompt, "That’s a good question"
    assert_includes prompt, "Never use \"par\" to mean friend"
    assert_includes persona.disclaimer, "inside Household CFO Method powered by VERA"
    assert_includes persona.uncertainty_line, "do not have enough approved data"
  end

  test "default persona includes Section 7 prompt seed verbatim" do
    persona = Mia::Persona.default

    assert_equal SECTION_7_SYSTEM_PROMPT_SEED, persona.system_prompt_seed
    assert_includes persona.system_prompt, SECTION_7_SYSTEM_PROMPT_SEED
  end

  test "persona seed is optional for future coach skins" do
    persona_data = Mia::Persona.default.data.deep_dup
    persona_data.delete("system_prompt_seed")
    persona = Mia::Persona.new("future_coach", persona_data)

    assert_nil persona.system_prompt_seed
    refute_includes persona.system_prompt, "Mia Persona Brief Section 7"
    assert_includes persona.system_prompt, "Product frame: the participant is the Household CFO"
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

  test "default persona includes crisis fallback that prioritizes immediate safety" do
    response = Mia::Persona.default.fallback_response(:crisis)

    assert_includes response, "988"
    assert_includes response, "911"
    assert_includes response, "getting support"
    refute_includes response.downcase, "monthly cushion"
  end
end
