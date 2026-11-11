require "test_helper"

class SavingsChallengeParticipantHelpTest < ActiveSupport::TestCase
  [ "I used to say I want to leave the challenge", "My friend said I want to leave the challenge",
    "I want to leave my job, what happens if I quit the challenge?", "I don't want to leave the challenge",
    "What happens if I quit the challenge?", "I'm thinking about stopping the challenge",
    "Don't tell my coach I want to leave the challenge" ].each do |message|
    test "discussion is not authorization: #{message}" do
      assert SavingsChallenge::ParticipantHelp.exit?(message)
      assert_not SavingsChallenge::ParticipantHelp.exit_requested?(message)
    end
  end

  [ "How do I quit the challenge?", "seriously how do i quit this challenge", "I want to pause the challenge",
    "Please pause the challenge", "I'm withdrawing from the savings challenge",
    "Can you let my coach know I want to leave the challenge?", "I spent $12 at Shell and I want to pause the challenge" ].each do |message|
    test "clear exit request authorizes notification: #{message}" do
      assert SavingsChallenge::ParticipantHelp.exit_requested?(message)
    end
  end
end
