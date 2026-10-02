# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaAssignmentCompatibilityTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "participant may join multiple cohorts that share one persona" do
    admin = persona_user(role: "admin")
    persona = published_persona(admin, assistant_name: "Shared assistant")
    first = cohort_for(admin, name: "First shared cohort")
    second = cohort_for(admin, name: "Second shared cohort")
    CohortPersonaAssignment.create!(cohort: first, coach_persona: persona, assigned_by_user: admin)
    CohortPersonaAssignment.create!(cohort: second, coach_persona: persona, assigned_by_user: admin)

    assert_nothing_raised do
      Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: [ first.id, second.id ])
    end
  end

  test "participant cannot join cohorts with different personas" do
    admin = persona_user(role: "admin")
    first_persona = published_persona(admin, assistant_name: "First compatibility assistant")
    second_persona = published_persona(admin, assistant_name: "Second compatibility assistant")
    first = cohort_for(admin, name: "First incompatible cohort")
    second = cohort_for(admin, name: "Second incompatible cohort")
    CohortPersonaAssignment.create!(cohort: first, coach_persona: first_persona, assigned_by_user: admin)
    CohortPersonaAssignment.create!(cohort: second, coach_persona: second_persona, assigned_by_user: admin)

    error = assert_raises(Mia::PersonaAssignmentCompatibility::Conflict) do
      Mia::PersonaAssignmentCompatibility.ensure_participant_can_join!(cohort_ids: [ first.id, second.id ])
    end

    assert_equal "This participant would receive different personas from their cohorts.", error.message
  end

  test "stale persona associations cannot pin a cohort to a superseded version" do
    admin = persona_user(role: "admin")
    persona = published_persona(admin, assistant_name: "Version one assistant")
    stale_persona = CoachPersona.find(persona.id)
    stale_version = stale_persona.current_published_version

    current_persona = CoachPersona.find(persona.id)
    revised = current_persona.draft_config.deep_merge("identity" => { "assistant_name" => "Version two assistant" })
    current_persona.update!(draft_config: revised)
    publish_persona(current_persona, actor: admin)

    cohort = cohort_for(admin, name: "Stale version cohort")
    assignment = CohortPersonaAssignment.new(
      cohort: cohort,
      coach_persona: stale_persona,
      coach_persona_version: stale_version,
      assigned_by_user: admin
    )

    refute assignment.save
    assert_includes assignment.errors[:coach_persona_version], "must be the persona's current published version"
  end

  test "stale persona associations cannot assign an archived persona" do
    admin = persona_user(role: "admin")
    persona = published_persona(admin, assistant_name: "Archived stale assistant")
    stale_persona = CoachPersona.find(persona.id)
    stale_version = stale_persona.current_published_version
    CoachPersona.find(persona.id).update!(archived_at: Time.current)

    assignment = CohortPersonaAssignment.new(
      cohort: cohort_for(admin, name: "Archived stale cohort"),
      coach_persona: stale_persona,
      coach_persona_version: stale_version,
      assigned_by_user: admin
    )

    refute assignment.save
    assert_includes assignment.errors[:coach_persona], "must be active and published before assignment"
  end

  private

  def cohort_for(creator, name:)
    Cohort.create!(name: name, status: "active", created_by_user: creator)
  end

  def persona_for(creator, assistant_name:)
    CoachPersona.create!(
      name: assistant_name,
      draft_config: persona_configuration(assistant_name: assistant_name, coach_name: creator.full_name),
      created_by_user: creator
    )
  end

  def published_persona(creator, assistant_name:)
    persona = persona_for(creator, assistant_name: assistant_name)
    publish_persona(persona, actor: creator)
    persona.reload
  end
end
