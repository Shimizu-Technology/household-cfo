# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaRuntimeResolutionContractTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @coach = persona_user
    @participant = persona_user(role: "participant")
  end

  test "effective cohort prefers active membership over a later enrolling cohort" do
    active = create_cohort(status: "active", starts_on: Date.new(2026, 8, 1))
    enrolling = create_cohort(status: "enrolling", starts_on: Date.new(2027, 1, 1))
    active_membership = add_participant(active)
    add_participant(enrolling)

    assert_equal active_membership, Mia::EffectiveCohortResolver.new(user: @participant).call
  end

  test "effective cohort has deterministic ordering and a latest-membership fallback" do
    first = create_cohort(status: "completed", starts_on: Date.new(2025, 1, 1))
    second = create_cohort(status: "archived", starts_on: Date.new(2025, 6, 1))
    add_participant(first, created_at: 2.days.ago)
    expected = add_participant(second, created_at: 1.day.ago)

    assert_equal expected, Mia::EffectiveCohortResolver.new(user: @participant).call
    assert_nil Mia::EffectiveCohortResolver.new(user: nil).call
  end

  test "persona resolver returns the effective cohort published runtime persona" do
    persona, version = publish_persona(assistant_name: "Coach Lila", coach_name: "Coach June")
    cohort = create_cohort(status: "active", starts_on: Date.new(2026, 8, 1))
    membership = add_participant(cohort)
    CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_persona: persona,
      assigned_by_user: @coach
    )

    resolved = Mia::PersonaResolver.new(user: @participant, cohort_membership: membership).call

    assert_instance_of Mia::RuntimePersona, resolved
    assert_equal version.id, resolved.version_id
    assert_equal persona.id, resolved.persona_id
    assert_equal "Coach Lila", resolved.name
    assert_includes resolved.disclaimer, "Coach June's approved guidance"
    assert_includes resolved.system_prompt, "Identity: The assistant is Coach Lila"
  end

  test "persona resolver falls back when active cohort assignments conflict" do
    first_persona, = publish_persona(assistant_name: "Coach Lila", coach_name: "Coach June")
    second_persona, = publish_persona(assistant_name: "Coach Nia", coach_name: "Coach Ana")
    active = create_cohort(status: "active", starts_on: Date.new(2026, 8, 1))
    enrolling = create_cohort(status: "enrolling", starts_on: Date.new(2026, 9, 1))
    active_membership = add_participant(active)
    add_participant(enrolling)
    CohortPersonaAssignment.create!(cohort: active, coach_persona: first_persona, assigned_by_user: @coach)
    CohortPersonaAssignment.create!(cohort: enrolling, coach_persona: second_persona, assigned_by_user: @coach)

    resolved = Mia::PersonaResolver.new(user: @participant, cohort_membership: active_membership).call

    assert_instance_of Mia::Persona, resolved
    assert_equal Mia::Persona::DEFAULT_ID, resolved.id
  end

  test "persona resolver never serves an assignment pinned to a superseded version" do
    persona, first = publish_persona(assistant_name: "Coach Lila", coach_name: "Coach June")
    cohort = create_cohort(status: "active", starts_on: Date.new(2026, 8, 1))
    membership = add_participant(cohort)
    assignment = CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: @coach)

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Measured and steady." }))
    second = publish_current(persona)
    assert_equal second, assignment.reload.coach_persona_version
    assignment.update_column(:coach_persona_version_id, first.id)

    resolved = Mia::PersonaResolver.new(user: @participant, cohort_membership: membership).call

    assert_instance_of Mia::Persona, resolved
    assert_equal Mia::Persona::DEFAULT_ID, resolved.id
  end

  private

  def create_cohort(status:, starts_on:)
    Cohort.create!(
      name: "Runtime cohort #{SecureRandom.hex(6)}",
      status: status,
      starts_on: starts_on,
      created_by_user: @coach
    )
  end

  def add_participant(cohort, created_at: Time.current)
    CohortMembership.create!(
      cohort: cohort,
      user: @participant,
      role: "participant",
      created_at: created_at,
      updated_at: created_at
    )
  end

  def publish_persona(assistant_name:, coach_name:)
    config = persona_configuration(assistant_name: assistant_name, coach_name: coach_name)
    persona = CoachPersona.create!(
      name: assistant_name,
      description: "Runtime persona contract fixture.",
      draft_config: config,
      created_by_user: @coach
    )
    [ persona, publish_current(persona) ]
  end

  def publish_current(persona)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: @coach)
    preview = publisher.preview!(expected_draft_revision: persona.reload.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id
    )
  end
end
