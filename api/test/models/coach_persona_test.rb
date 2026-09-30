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

  test "editing a draft increments revision and invalidates only its preview" do
    persona = create_persona
    preview = Mia::PersonaPublisher.new(persona: persona, actor: persona.created_by_user).preview!(expected_draft_revision: 1)
    assert_equal preview.fetch(:digest), persona.reload.preview_digest

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Warm and energetic." }))

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
end
