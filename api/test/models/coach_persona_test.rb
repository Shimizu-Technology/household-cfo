# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachPersonaTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "coach owns a strict draft and different coaches may use the same name" do
    first_coach = persona_user(email: "first-coach@example.com")
    second_coach = persona_user(email: "second-coach@example.com")
    create_persona(creator: first_coach, name: "Mia")

    assert create_persona(creator: second_coach, name: "Mia").persisted?
    duplicate = CoachPersona.new(name: "mia", draft_config: persona_configuration, created_by_user: first_coach)
    refute duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "participant cannot create a coach persona" do
    persona = CoachPersona.new(
      name: "Participant persona",
      draft_config: persona_configuration,
      created_by_user: persona_user(role: "participant")
    )

    refute persona.valid?
    assert_includes persona.errors[:created_by_user], "must be a coach or admin"
  end

  test "historical creator demotion does not brick an existing persona lifecycle" do
    creator = persona_user
    admin = persona_user(role: "admin")
    persona = create_persona(creator: creator)
    reviewer = persona_user
    persona.coach_workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    creator.update!(role: "participant")

    persona.update!(description: "Maintained by an authorized admin after creator demotion.")
    version = publish_persona(persona, actor: admin, reviewer: reviewer)
    persona.archive!
    persona.restore!

    assert_equal version, persona.reload.current_published_version
    refute persona.archived?
  end

  test "editing a draft increments revision and invalidates only its preview" do
    persona = create_persona
    preview = Mia::PersonaPublisher.new(persona: persona, actor: persona.created_by_user).preview!(expected_draft_revision: 1)
    assert_equal preview.fetch(:digest), persona.reload.preview_digest

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Direct and energetic." }))

    assert_equal 2, persona.draft_revision
    assert_nil persona.preview_digest
    assert_nil persona.previewed_at
    assert_nil persona.previewed_draft_revision

    persona.update!(description: "Editorial change")
    assert_equal 2, persona.draft_revision
  end

  test "lock version detects a stale coach edit" do
    persona = create_persona
    first_copy = CoachPersona.find(persona.id)
    stale_copy = CoachPersona.find(persona.id)
    first_copy.update!(description: "First edit")

    assert_raises(ActiveRecord::StaleObjectError) { stale_copy.update!(description: "Stale edit") }
  end

  test "archive helpers preserve the persona while removing it from active scope" do
    persona = create_persona

    persona.archive!
    assert persona.archived?
    refute_includes CoachPersona.active, persona
    assert_includes CoachPersona.archived, persona
    refute persona.update(description: "Archived edit")
    assert_includes persona.errors[:base], "archived personas are read-only until restored"
    persona.reload

    persona.restore!
    refute persona.archived?
  end

  test "live cohort assignments include only draft enrolling and active cohorts" do
    persona = create_persona(name: "Assignment status assistant")
    version = publish_persona(persona, actor: persona.created_by_user)
    cohort = cohort_for(persona.created_by_user, name: "Assignment status cohort")
    CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_persona: persona,
      coach_persona_version: version,
      assigned_by_user: persona.created_by_user
    )

    %w[draft enrolling active].each do |status|
      cohort.update!(status: status)
      assert persona.live_cohort_assignments?, "expected #{status} to remain live"
    end
    %w[completed archived].each do |status|
      cohort.update!(status: status)
      refute persona.live_cohort_assignments?, "expected #{status} to be inactive"
    end
  end
end
