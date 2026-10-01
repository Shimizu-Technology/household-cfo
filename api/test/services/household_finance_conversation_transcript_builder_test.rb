require "test_helper"
require_relative "../support/persona_test_helper"

class HouseholdFinanceConversationTranscriptBuilderTest < ActiveSupport::TestCase
  include PersonaTestHelper
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

  test "keeps the most recent turns that fit within the aggregate character budget" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "transcript-budget@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Transcript Budget Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")

    20.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Turn #{index + 1}: #{'x' * 1_850}")
    end

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call

    assert_operator transcript.length, :<, 20
    assert_operator transcript.sum { |message| message.fetch(:content).length }, :<=,
      HouseholdFinance::ConversationTranscriptBuilder::MAX_TOTAL_CHARACTERS
    assert_includes transcript.last.fetch(:content), "Turn 20"
  end

  test "keeps the complete accepted user message when decisive facts are near character eight thousand" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "transcript-long-message@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Long Transcript Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    decisive_tail = "Set Groceries to $900 for August 2026."
    content = ("x" * (ChatMessage::MAX_USER_CONTENT_LENGTH - decisive_tail.length)) + decisive_tail
    message = session.chat_messages.create!(role: "user", content: content)

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call

    assert_equal ChatMessage::MAX_USER_CONTENT_LENGTH, transcript.sole.fetch(:content).length
    assert_equal message.content, transcript.sole.fetch(:content)
    assert transcript.sole.fetch(:content).end_with?(decisive_tail)
  end

  test "never exceeds the aggregate context budget with maximum length messages" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "transcript-hard-budget@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Bounded Transcript Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")

    4.times do |index|
      marker = "message-#{index + 1}:"
      content = marker + ("x" * (ChatMessage::MAX_CONTENT_LENGTH - marker.length))
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: content)
    end

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call

    assert_equal 3, transcript.length
    assert_operator transcript.sum { |message| message.fetch(:content).length }, :<=,
      HouseholdFinance::ConversationTranscriptBuilder::MAX_TOTAL_CHARACTERS
    assert transcript.first.fetch(:content).start_with?("message-2:")
    assert transcript.last.fetch(:content).start_with?("message-4:")
  end

  test "keeps user turns while excluding assistant turns from other persona versions" do
    coach = persona_user
    participant = persona_user(role: "participant")
    household = Household.create!(created_by_user: participant, name: "Versioned Transcript Household")
    session = household.chat_sessions.create!(user: participant, title: "Ask coach")
    persona = CoachPersona.create!(
      name: "Coach Lila",
      draft_config: persona_configuration(assistant_name: "Coach Lila", coach_name: "Coach June"),
      created_by_user: coach
    )
    first_version = publish_persona(persona, coach)
    session.chat_messages.create!(role: "assistant", content: "Legacy global answer.")
    session.chat_messages.create!(role: "assistant", content: "Retired persona answer.", assistant_author: "Coach Lila", coach_persona_version: first_version)
    session.chat_messages.create!(role: "user", content: "Keep my question across persona updates.")
    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Steady and reassuring." }))
    current_version = publish_persona(persona, coach)
    session.chat_messages.create!(role: "assistant", content: "Current persona answer.", assistant_author: "Coach Lila", coach_persona_version: current_version)

    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(
      session,
      persona_version_id: current_version.id
    ).call

    assert_equal [ "Keep my question across persona updates.", "Current persona answer." ], transcript.pluck(:content)
    assert_equal [ nil, current_version.id ], transcript.pluck(:coach_persona_version_id)
  end

  private

  def publish_persona(persona, coach)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    preview = publisher.preview!(expected_draft_revision: persona.reload.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id
    )
  end
end
