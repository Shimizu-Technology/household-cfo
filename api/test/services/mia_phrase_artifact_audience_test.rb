# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPhraseArtifactAudienceTest < ActiveSupport::TestCase
  include PersonaTestHelper

  COACH_PHRASE = "Steady steps"
  PARTICIPANT_PHRASE = "Auntie's grocery rule"

  setup do
    @coach = persona_user
    @participant = persona_user(role: "participant")
    @other_participant = persona_user(role: "participant")
    config = persona_configuration(assistant_name: "Coach Lila", coach_name: "Coach June")
    config["phrases"] = [
      persona_phrase_artifact(
        {
          "text" => COACH_PHRASE,
          "meaning" => "The coach's reminder to take one manageable action.",
          "allowed_contexts" => [ "routine" ],
          "frequency" => "as_needed"
        },
        source_user_id: @coach.id
      ),
      persona_phrase_artifact(
        {
          "text" => PARTICIPANT_PHRASE,
          "meaning" => "The participant's own name for reviewing grocery choices.",
          "allowed_contexts" => [ "routine" ],
          "frequency" => "as_needed",
          "caution" => "Use only for the participant who supplied it."
        },
        source_user_id: @participant.id,
        provenance: "participant_supplied"
      )
    ]
    persona = CoachPersona.create!(
      name: "Coach Lila",
      description: "Audience-scoped phrase fixture.",
      draft_config: config,
      created_by_user: @coach
    )
    @version = publish_persona(persona, actor: @coach)
    @cohort = Cohort.create!(name: "Shared persona cohort", status: "active", created_by_user: @coach)
    @membership = @cohort.cohort_memberships.create!(user: @participant, role: "participant")
    @other_membership = @cohort.cohort_memberships.create!(user: @other_participant, role: "participant")
    CohortPersonaAssignment.create!(cohort: @cohort, coach_persona: persona, assigned_by_user: @coach)
  end

  test "a shared cohort persona scopes participant artifacts to their source participant" do
    source_runtime = resolve(@participant, @membership)
    other_runtime = resolve(@other_participant, @other_membership)

    assert_equal @version.id, source_runtime.version_id
    assert_equal @version.id, other_runtime.version_id
    assert_includes source_runtime.system_prompt, COACH_PHRASE
    assert_includes other_runtime.system_prompt, COACH_PHRASE
    assert_includes source_runtime.system_prompt, PARTICIPANT_PHRASE
    refute_includes other_runtime.system_prompt, PARTICIPANT_PHRASE
    refute_includes source_runtime.system_prompt, "source_user_id"
    refute_includes other_runtime.system_prompt, "source_user_id"
  end

  test "same participant output authorization preserves their phrase and respects transcript frequency" do
    runtime = resolve(@participant, @membership)
    current = policy(runtime).sanitize("#{PARTICIPANT_PHRASE}, review groceries today.")
    repeated = policy(
      runtime,
      history: [ { role: "assistant", content: "#{PARTICIPANT_PHRASE}, we checked the list." } ]
    ).sanitize("#{PARTICIPANT_PHRASE}, review groceries today.")

    assert_equal "#{PARTICIPANT_PHRASE}, review groceries today.", current
    assert_equal "Review groceries today.", repeated
  end

  test "another participant cannot authorize a phrase through their message or transcript" do
    runtime = resolve(@other_participant, @other_membership)
    answer = Mia::LanguagePolicy.new(
      user_message: "#{PARTICIPANT_PHRASE}, what is next?",
      history: [ { role: "assistant", content: "#{PARTICIPANT_PHRASE}, we used that wording before." } ],
      persona: runtime
    ).sanitize("#{PARTICIPANT_PHRASE}, review groceries today.")

    assert_equal "Review groceries today.", answer
  end

  test "runtime without a proven participant fails closed for participant artifacts" do
    runtime = Mia::RuntimePersona.new(@version)
    mismatched_runtime = resolve(@participant, @other_membership)

    [ runtime, mismatched_runtime ].each do |candidate|
      refute_includes candidate.system_prompt, PARTICIPANT_PHRASE
      assert_includes candidate.system_prompt, COACH_PHRASE
      assert_equal "Review groceries today.", policy(candidate).sanitize("#{PARTICIPANT_PHRASE}, review groceries today.")
    end
  end

  test "direct construction cannot forge participant audience with a numeric source id" do
    assert_raises(ArgumentError) do
      Mia::RuntimePersona.new(@version, participant_id: @participant.id)
    end

    forged_config = @version.config.deep_dup
    forged_config["phrases"] = [
      persona_phrase_artifact(
        {
          "text" => "Private family wording",
          "meaning" => "Participant-supplied family language.",
          "allowed_contexts" => [ "routine" ]
        },
        source_user_id: 4242,
        provenance: "participant_supplied"
      )
    ]
    direct_runtime = Mia::RuntimePersona.new(
      nil,
      config: forged_config,
      identifier: "forged_runtime",
      persona_id: @version.coach_persona_id
    )

    refute_includes direct_runtime.system_prompt, "Private family wording"
    assert_equal "Review groceries today.",
      policy(direct_runtime).sanitize("Private family wording, review groceries today.")
  end

  test "verified factory reloads persisted relationships before granting participant audience" do
    runtime = Mia::RuntimePersona.for_participant(
      version: @version,
      user: @participant,
      cohort_membership: @membership
    )
    forged_membership = @other_membership.dup
    forged_membership.id = @membership.id
    forged_membership.user = @participant
    unverified = Mia::RuntimePersona.for_participant(
      version: @version,
      user: @other_participant,
      cohort_membership: forged_membership
    )

    assert_includes runtime.system_prompt, PARTICIPANT_PHRASE
    refute_includes unverified.system_prompt, PARTICIPANT_PHRASE
  end

  test "built-in demo persona history remains unchanged" do
    content = "Håfa Adai, let us review the plan."

    assert_equal content,
      Mia::LanguagePolicy.redact_unauthorized_phrase_artifacts(content, persona: Mia::Persona.default)
  end

  test "responder and narrator use the same scoped prompt output policy and transcript" do
    source_runtime = resolve(@participant, @membership)
    other_runtime = resolve(@other_participant, @other_membership)
    history = [ { role: "assistant", content: "#{PARTICIPANT_PHRASE}, we checked the list." } ]

    source_responder = Demo::MiaResponder.new(persona: source_runtime)
    other_responder = Demo::MiaResponder.new(persona: other_runtime)
    assert_includes source_responder.send(:conversation_history, history).sole.fetch(:content), PARTICIPANT_PHRASE
    refute_includes other_responder.send(:conversation_history, history).sole.fetch(:content), PARTICIPANT_PHRASE
    assert_equal "Review groceries today.", other_responder.send(
      :sanitize_assistant_content,
      "#{PARTICIPANT_PHRASE}, review groceries today.",
      user_message: "What should I do?",
      history: history
    )

    source_narrator = narrator(source_runtime, history: history)
    other_narrator = narrator(other_runtime, history: history)
    assert_includes source_narrator.send(:payload).fetch(:messages).first.fetch(:content), PARTICIPANT_PHRASE
    refute_includes other_narrator.send(:payload).fetch(:messages).first.fetch(:content), PARTICIPANT_PHRASE
    assert_includes source_narrator.send(:conversation_history).sole.fetch(:content), PARTICIPANT_PHRASE
    refute_includes other_narrator.send(:conversation_history).sole.fetch(:content), PARTICIPANT_PHRASE
    assert_equal "Review groceries today.", other_narrator.send(:sanitize_narration, "#{PARTICIPANT_PHRASE}, review groceries today.")
  end

  private

  def resolve(user, membership)
    Mia::PersonaResolver.new(user: user, cohort_membership: membership).call
  end

  def policy(runtime, history: [])
    Mia::LanguagePolicy.new(user_message: "What should I do next?", history: history, persona: runtime)
  end

  def narrator(runtime, history: [])
    HouseholdFinance::MiaNarrator.new(
      user_message: "What should I do next?",
      history: history,
      answer_packet: {
        kind: "coaching",
        fallback_response: "Review groceries today. Then choose one next move.",
        write_state: "no_write"
      },
      persona: runtime
    )
  end
end
