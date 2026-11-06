# frozen_string_literal: true

require "test_helper"

class MiaPersonaSetupCoachSourceProseTest < ActiveSupport::TestCase
  test "possessive descriptions before a colon keep her exact authored saying" do
    [ "My manner is a warm older cousin: patient and practical.", "My coaching style is steady: I listen first.", "My voice stays grounded: no hype." ].each do |intro|
      message = "#{intro} When a purchase would leave no money for bills, I say \"One step first.\" It means pause before buying."
      assert_equal message, Mia::PersonaSetup::CoachSource.new.body(message)
      assert_equal "One step first.", Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("One step first.")
    end
  end

  test "prose attribution is preserved in full for the semantic guard" do
    [ 'My client: I say "Pay up."', 'My voice stays grounded. Client: I say "Pay up."', 'My coaching style is steady. Sister: I say "Pay up."', 'My client says: I say "Pay up."' ].each do |message|
      assert_equal message, Mia::PersonaSetup::CoachSource.new(message: message).body(message)
      assert_equal "Pay up.", Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Pay up.")
    end
  end

  test "only a short label at the start of a transcript line identifies a speaker" do
    message = "Suggest my voice from this transcript.\nMaria: I say \"Not mine.\"\nCoach: I say \"Pause.\""
    source = Mia::PersonaSetup::CoachSource.new(message: message)
    assert_nil source.body(message.lines[1])
    assert_equal "I say \"Pause.\"", source.body(message.lines[2])
    assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Not mine.")
    assert_equal "Pause.", Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Pause.")
  end
end
