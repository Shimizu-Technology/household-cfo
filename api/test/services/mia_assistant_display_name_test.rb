require "test_helper"

class MiaAssistantDisplayNameTest < ActiveSupport::TestCase
  test "drops the program label coaches add to the assistant name" do
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia for Mrs. Mel BOG")
    assert_equal "Mia", Mia::AssistantDisplayName.short("  Mia   FOR   BOG pilot ")
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia (BOG pilot)")
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia - BOG")
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia — Bank of Guam")
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia | savings")
  end

  test "keeps names that are already a name" do
    assert_equal "Mia", Mia::AssistantDisplayName.short("Mia")
    assert_equal "Coach Lila", Mia::AssistantDisplayName.short("Coach Lila")
    assert_equal "Coach Lila Next", Mia::AssistantDisplayName.short("Coach Lila Next")
    assert_equal "Mia-Rose", Mia::AssistantDisplayName.short("Mia-Rose")
    assert_equal "Fortune", Mia::AssistantDisplayName.short("Fortune")
  end

  test "falls back to the full name when no usable short part exists" do
    assert_equal "(BOG) Mia", Mia::AssistantDisplayName.short("(BOG) Mia")
    assert_equal "", Mia::AssistantDisplayName.short(nil)
  end

  test "runtime persona disclaimer names the assistant by its short name" do
    config = Mia::PersonaSchema.default_configuration(assistant_name: "Mia for Mrs. Mel BOG", human_coach_name: "Mrs. Mel")
    persona = Mia::RuntimePersona.for_preview(config: config, persona_id: 7, draft_revision: 1)

    assert_equal "Mia for Mrs. Mel BOG", persona.name
    assert persona.disclaimer.start_with?("Mia is an AI coaching assistant built from Mrs. Mel's approved guidance.")
    refute_includes persona.disclaimer, "BOG"
  end
end
