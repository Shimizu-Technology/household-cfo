require "test_helper"

class SavingsChallengeParticipantHelpTest < ActiveSupport::TestCase
  test "wording only offers a card, including questions reasons and combined reminders" do
    help = SavingsChallenge::ParticipantHelp
    {
      "I want to quit the challenge, should I?" => [ "leave" ],
      "I want to leave the challenge because this takes too much time" => [ "leave" ],
      "I want to quit the challenge and turn off reminders" => [ "leave" ],
      "Please pause the challenge" => [ "pause" ],
      "I want to stop the challenge" => [ "leave", "pause" ],
      "Should I pause or leave the challenge?" => [ "pause", "leave" ],
      "Don't tell my coach I want to quit" => [],
      "Please pause the challenge, but don't pause the challenge" => [],
      "I don't want to quit but I want to pause the challenge" => [ "pause" ]
    }.each do |message, intents|
      assert_equal intents, help.card_intents(message), message
      refute_includes help.exit_answer(message), "I've let your coach know"
    end
    assert_includes help.exit_answer("I want to quit the challenge and turn off reminders"), "turn off"
    assert_includes help.exit_answer("Can you turn on reminders for me?"), "turn on"
  end
  test "unrelated quitting does not become challenge leave intent" do
    help = SavingsChallenge::ParticipantHelp
    [ "I want to quit smoking. When does my challenge end?", "I want to quit smoking, when does my challenge end?",
      "I want to quit smoking when does my challenge end?", "I want to leave work and see my challenge dates" ].each do |message|
      refute help.exit?(message)
      assert_empty help.card_intents(message)
    end
    assert_equal [ "pause" ], help.card_intents("I want to quit smoking and pause the challenge")
    assert_equal [ "leave" ], help.card_intents("I want to pause my gym membership but leave the challenge")
    message = "I want to quit the challenge and turn off reminders"
    assert_equal 1, help.exit_answer(message).scan(/Nothing (?:has|about)/).size
  end

  test "naming words between the verb and the challenge still offer a card" do
    help = SavingsChallenge::ParticipantHelp
    {
      "I want to quit the 90-day challenge" => [ "leave" ],
      "I want to leave the BOG savings challenge" => [ "leave" ],
      "How do I leave the Bank of Guam challenge?" => [ "leave" ],
      "I want to quit this whole challenge thing" => [ "leave" ],
      "I need to take a break from the challenge" => [ "pause" ],
      "Can I stop doing the challenge?" => [ "leave", "pause" ]
    }.each { |message, intents| assert_equal intents, help.card_intents(message), message }
    assert_empty help.card_intents("I want to quit smoking before my challenge starts")
  end

  test "reminder direction comes from the reminder clause" do
    help = SavingsChallenge::ParticipantHelp
    assert_includes help.reminder_answer("How do I turn off reminders when I start the challenge?"), "turn off"
    assert_includes help.reminder_answer("Can you turn on reminders for me?"), "turn on"
    assert_includes help.reminder_answer("Please stop the reminders"), "turn off"
  end
end
