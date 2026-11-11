require "test_helper"

class SavingsChallengeParticipantHelpTest < ActiveSupport::TestCase
  [ "How do I quit the challenge?", "seriously how do i quit this challenge", "I used to say I want to leave the challenge", "My friend said I want to leave the challenge",
    "I want to leave my job, what happens if I quit the challenge?", "I don't want to leave the challenge",
    "What happens if I quit the challenge?", "I'm thinking about stopping the challenge",
    "Don't tell my coach I want to leave the challenge" ].each do |message|
    test "discussion is not authorization: #{message}" do
      assert SavingsChallenge::ParticipantHelp.exit?(message)
      assert_not SavingsChallenge::ParticipantHelp.exit_requested?(message)
    end
  end

  [ "I want to pause the challenge",
    "Please pause the challenge", "I'm withdrawing from the savings challenge",
    "Can you let my coach know I want to leave the challenge?", "I spent $12 at Shell and I want to pause the challenge" ].each do |message|
    test "clear exit request authorizes notification: #{message}" do
      assert SavingsChallenge::ParticipantHelp.exit_requested?(message)
    end
  end
end

class SavingsChallengeParticipantHelpTest < ActiveSupport::TestCase
  test "clear request clauses tolerate unrelated negation and keep pause distinct from leave" do
    {
      "Please tell my coach I want to quit the challenge. I'm not happy with it." => :leave,
      "I want to quit the challenge, I don't have the money anymore" => :leave,
      "I don't want to quit but I want to pause the challenge" => :pause,
      "Take me out of the program please" => :leave
    }.each { |text, intent| assert_equal intent, SavingsChallenge::ParticipantHelp.exit_request_intent(text), text }
  end
  test "refused consent uncertainty retraction and procedural questions never notify" do
    [ "Please don't tell my coach, I want to quit the challenge", "I want to quit the challenge but I'm not sure yet",
      "I want to leave the challenge? lol no", "Can I leave?", "How do I quit?", "How do I quit the challenge?",
      "I don't want to quit the challenge", "I put $50 aside today, but I am thinking about stopping the challenge, how do I pause it?" ].each do |text|
      assert SavingsChallenge::ParticipantHelp.exit?(text), text
      assert_not SavingsChallenge::ParticipantHelp.exit_requested?(text), text
    end
  end
  test "reminder instructions respect on versus off without leave consent" do
    assert_match(/turn on the reminders you want/, SavingsChallenge::ParticipantHelp.reminder_answer("Can you turn on reminders for me?"))
    assert_match(/turn off the reminders you don't want/, SavingsChallenge::ParticipantHelp.reminder_answer("Stop the challenge reminders please"))
    assert_not SavingsChallenge::ParticipantHelp.exit_requested?("Can you turn on reminders for me?")
  end
end
