require "test_helper"

class HouseholdFinanceConversationTranscriptBuilderTest < ActiveSupport::TestCase
  test "keeps a token bounded recent transcript instead of a fixed twelve message window" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "transcript@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Transcript Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")

    40.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Message #{index + 1}")
    end

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call

    assert_equal 32, transcript.length
    assert_equal "Message 9", transcript.first.fetch(:content)
    assert_equal "Message 40", transcript.last.fetch(:content)
    assert_equal %w[user assistant], transcript.last(2).map { |message| message.fetch(:role) }
    assert transcript.all? { |message| message.key?(:id) && message.key?(:created_at) }
  end

  test "keeps at least the most recent eight turns when older messages exceed the character budget" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "transcript-budget@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Transcript Budget Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")

    20.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Turn #{index + 1}: #{'x' * 1_850}")
    end

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call

    assert_operator transcript.length, :>=, 8
    assert_operator transcript.length, :<, 20
    assert_includes transcript.last.fetch(:content), "Turn 20"
  end
end
