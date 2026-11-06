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

  test "possessive client labels and a following speaker remain other people" do
    [ 'My client: I say "Pay up."', 'My voice stays grounded. Client: I say "Pay up."', 'My coaching style is steady. Sister: I say "Pay up."', 'My client says: I say "Pay up."' ].each do |message|
      assert_nil Mia::PersonaSetup::CoachSource.new.body(message)
      assert_nil Mia::PersonaSetup::PhraseSuggestions.new(message: message).exact_quote("Pay up.")
    end
  end
end
