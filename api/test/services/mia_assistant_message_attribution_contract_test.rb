# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaAssistantMessageAttributionContractTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @participant = persona_user(role: "participant")
    @persona, @version = publish_persona
    @runtime = Mia::RuntimePersona.new(@version)
    @cohort = Cohort.create!(
      name: "Attribution cohort #{SecureRandom.hex(6)}",
      status: "active",
      starts_on: Date.new(2026, 8, 1),
      created_by_user: @coach
    )
    @membership = @cohort.cohort_memberships.create!(user: @participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: @cohort, coach_persona: @persona, assigned_by_user: @coach)
    @household = Household.create!(name: "Attribution household", created_by_user: @participant)
    @household.household_memberships.create!(user: @participant, role: "owner")
    @session = @household.chat_sessions.create!(user: @participant, title: "Ask coach")
  end

  test "assistant writer snapshots author and immutable published version" do
    message = Mia::AssistantMessageWriter.new(session: @session, persona: @runtime).create!(
      content: "Use the confirmed plan for the next decision."
    )

    assert_equal "assistant", message.role
    assert_equal "Coach Lila", message.assistant_author
    assert_equal @version, message.coach_persona_version
    assert_equal "Coach Lila", message.as_api_json.fetch(:author)
  end

  test "historical author and version remain stable after a later publish" do
    message = Mia::AssistantMessageWriter.new(session: @session, persona: @runtime).create!(content: "Version one answer.")
    @persona.update!(
      draft_config: @persona.draft_config.deep_merge(
        "identity" => { "assistant_name" => "Coach Lila Next" },
        "voice" => { "energy" => "Steady and reassuring." }
      )
    )
    second = publish_current

    assert_equal second, @cohort.cohort_persona_assignment.reload.coach_persona_version
    assert_equal @version, message.reload.coach_persona_version
    assert_equal "Coach Lila", message.assistant_author
    assert_equal "Coach Lila", message.as_api_json.fetch(:author)
  end

  test "data presenter uses one cohort persona for profile disclaimer and history" do
    written = Mia::AssistantMessageWriter.new(session: @session, persona: @runtime).create!(content: "A published coach answer.")

    payload = HouseholdFinance::DataPresenter.new(@household, user: @participant).app_data

    assert_equal @cohort.id, payload.dig(:workspace, :cohort, :id)
    assert_equal "Coach Lila", payload.dig(:profile, :coach, :name)
    assert_includes payload.dig(:mia, :disclaimer), "Coach Lila"
    historical = payload.dig(:mia, :messages).find { |message| message.fetch(:id) == written.id }
    assert_equal "Coach Lila", historical.fetch(:author)
  end

  test "legacy assistant messages keep the global Mia attribution" do
    message = @session.chat_messages.create!(role: "assistant", content: "Legacy answer.")

    assert_nil message.coach_persona_version
    assert_equal "Mia", message.assistant_author
    assert_equal "Mia", message.as_api_json.fetch(:author)
  end

  test "user messages cannot carry assistant persona attribution" do
    message = @session.chat_messages.build(
      role: "user",
      content: "My question",
      assistant_author: "Coach Lila",
      coach_persona_version: @version
    )

    refute message.valid?
    assert_includes message.errors[:assistant_author], "and persona version are available only on assistant messages"
  end

  private

  def publish_persona
    config = persona_configuration(assistant_name: "Coach Lila", coach_name: "Coach June")
    persona = CoachPersona.create!(
      name: "Coach Lila",
      description: "Attribution persona contract fixture.",
      draft_config: config,
      created_by_user: @coach
    )
    @persona = persona
    [ persona, publish_current ]
  end

  def publish_current
    PersonaTestHelper.instance_method(:publish_persona).bind_call(self, @persona, actor: @coach)
  end
end
