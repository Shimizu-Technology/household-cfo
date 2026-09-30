# frozen_string_literal: true

require "test_helper"

class ApiV1AdminUserPersonaCompatibilityTest < ActionDispatch::IntegrationTest
  test "coach access to participants requires a coach-role cohort membership" do
    admin = create_user(role: "admin")
    coach = create_user(role: "coach")
    participant = create_user(role: "participant")
    cohort = Cohort.create!(name: "Participant-role staff cohort", status: "active", created_by_user: admin)
    coach.cohort_memberships.create!(cohort: cohort, role: "participant")
    participant.cohort_memberships.create!(cohort: cohort, role: "participant")

    get "/api/v1/admin/users", headers: auth_headers(coach)

    assert_response :success
    refute_includes response.parsed_body.fetch("users").pluck("id"), participant.id
  end

  test "participant cannot be placed in active cohorts with different personas" do
    admin = create_user(role: "admin")
    participant = create_user(role: "participant")
    first = Cohort.create!(name: "First persona cohort", status: "active", created_by_user: admin)
    second = Cohort.create!(name: "Second persona cohort", status: "active", created_by_user: admin)
    first.cohort_persona_assignment = assignment_for(first, published_persona(admin, "Ari"), admin)
    second.cohort_persona_assignment = assignment_for(second, published_persona(admin, "Bea"), admin)

    patch "/api/v1/admin/users/#{participant.id}",
      params: { user: { role: "participant", cohort_ids: [ first.id, second.id ] } },
      headers: auth_headers(admin),
      as: :json

    assert_response :conflict
    assert_equal "persona_assignment_conflict", response.parsed_body.fetch("code")
    assert_empty participant.reload.cohort_memberships
  end

  private

  def create_user(role:)
    User.create!(
      clerk_id: "persona-user-scope-#{SecureRandom.hex(8)}",
      email: "persona-user-scope-#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end

  def published_persona(user, name)
    persona = CoachPersona.create!(
      name: name,
      draft_config: Mia::PersonaSchema.default_configuration(
        assistant_name: name,
        human_coach_name: user.full_name.presence || user.email
      ),
      created_by_user: user
    )
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: user)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil
    )
    persona.reload
  end

  def assignment_for(cohort, persona, user)
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: user)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
