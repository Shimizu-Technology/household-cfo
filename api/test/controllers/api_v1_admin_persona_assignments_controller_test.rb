# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminPersonaAssignmentsControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "assignment endpoints require staff and coach-role cohort membership" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant")
    cohort = cohort_for(admin, name: "Strict coach scope")
    coach.cohort_memberships.create!(cohort: cohort, role: "participant")

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment"
    assert_response :unauthorized

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment", headers: auth_headers(participant)
    assert_response :forbidden

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment", headers: auth_headers(coach)
    assert_response :not_found

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment", headers: auth_headers(admin)
    assert_response :success
    assert_nil response.parsed_body.fetch("persona_assignment")
  end

  test "published persona assignment supports show replace delete and stale-write protection" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    cohort = cohort_for(admin, name: "Assignment lifecycle")
    coach.cohort_memberships.create!(cohort: cohort, role: "coach")
    first = published_persona(coach, assistant_name: "First assistant")
    second = published_persona(coach, assistant_name: "Second assistant")

    patch_assignment(cohort, coach, persona_id: first.id, expected_persona_id: nil)

    assert_response :success
    assignment = CohortPersonaAssignment.find(response.parsed_body.dig("persona_assignment", "id"))
    assert_equal first, assignment.coach_persona
    assert_equal first.current_published_version, assignment.coach_persona_version
    assert_equal coach, assignment.assigned_by_user

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment", headers: auth_headers(coach)
    assert_response :success
    assert_equal first.id, response.parsed_body.dig("persona_assignment", "persona", "id")

    patch_assignment(cohort, coach, persona_id: second.id, expected_persona_id: nil)
    assert_response :conflict
    assert_equal "persona_assignment_stale", response.parsed_body.fetch("code")
    assert_equal first, assignment.reload.coach_persona

    patch_assignment(cohort, coach, persona_id: second.id, expected_persona_id: first.id)
    assert_response :success
    assert_equal second, assignment.reload.coach_persona

    delete_assignment(cohort, coach, expected_persona_id: first.id)
    assert_response :conflict
    assert CohortPersonaAssignment.exists?(assignment.id)

    delete_assignment(cohort, coach, expected_persona_id: second.id)
    assert_response :no_content
    refute CohortPersonaAssignment.exists?(assignment.id)
  end

  test "coach cannot assign another coach persona or a draft persona" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    other_coach = persona_user(role: "coach")
    cohort = cohort_for(admin, name: "Ownership boundary")
    coach.cohort_memberships.create!(cohort: cohort, role: "coach")
    other_persona = published_persona(other_coach, assistant_name: "Other coach assistant")
    draft = persona_for(coach, assistant_name: "Draft assistant")

    patch_assignment(cohort, coach, persona_id: other_persona.id, expected_persona_id: nil)
    assert_response :not_found

    patch_assignment(cohort, coach, persona_id: draft.id, expected_persona_id: nil)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Publish this persona before assigning it."

    patch_assignment(cohort, admin, persona_id: other_persona.id, expected_persona_id: nil)
    assert_response :success
  end

  test "completed cohorts expose their assignment but reject update and removal" do
    admin = persona_user(role: "admin")
    persona = published_persona(admin, assistant_name: "Completed assistant")
    cohort = cohort_for(admin, name: "Completed persona cohort", status: "active")
    assignment = CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: admin)
    cohort.update!(status: "completed")

    get "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment", headers: auth_headers(admin)
    assert_response :success
    assert_equal assignment.id, response.parsed_body.dig("persona_assignment", "id")

    patch_assignment(cohort, admin, persona_id: persona.id, expected_persona_id: persona.id)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Completed cohorts are read-only."

    delete_assignment(cohort, admin, expected_persona_id: persona.id)
    assert_response :unprocessable_entity
    assert CohortPersonaAssignment.exists?(assignment.id)
  end

  test "multi-cohort persona conflict is rejected without leaking participant identity or financial data" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    participant = persona_user(role: "participant", email: "private-participant@example.com")
    target = cohort_for(admin, name: "Target cohort")
    other = cohort_for(admin, name: "Other assigned cohort")
    [ target, other ].each do |cohort|
      coach.cohort_memberships.create!(cohort: cohort, role: "coach")
      participant.cohort_memberships.create!(cohort: cohort, role: "participant")
    end
    target_persona = published_persona(coach, assistant_name: "Target assistant")
    other_persona = published_persona(coach, assistant_name: "Other assistant")
    CohortPersonaAssignment.create!(cohort: other, coach_persona: other_persona, assigned_by_user: coach)
    household = Household.create!(name: "Private household name", created_by_user: participant)
    household.household_memberships.create!(user: participant, role: "owner")

    patch_assignment(target, coach, persona_id: target_persona.id, expected_persona_id: nil)

    assert_response :conflict
    body = response.parsed_body
    assert_equal "persona_assignment_conflict", body.fetch("code")
    conflict = body.fetch("conflicts").sole
    assert_equal 1, conflict.fetch("participant_count")
    refute conflict.key?("cohort_id")
    refute conflict.key?("cohort_name")
    assert_not_includes response.body, other.name
    assert_not_includes response.body, participant.email
    assert_not_includes response.body, household.name
    assert_nil target.reload.cohort_persona_assignment
  end

  test "assignable cohort list is scoped and marks completed cohorts read only" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    active = cohort_for(admin, name: "Assignable active", status: "active")
    completed = cohort_for(admin, name: "Assignable completed", status: "completed")
    hidden = cohort_for(admin, name: "Hidden cohort", status: "active")
    coach.cohort_memberships.create!(cohort: active, role: "coach")
    coach.cohort_memberships.create!(cohort: completed, role: "coach")
    coach.cohort_memberships.create!(cohort: hidden, role: "participant")

    get "/api/v1/admin/personas/assignable_cohorts", headers: auth_headers(coach)

    assert_response :success
    rows = response.parsed_body.fetch("cohorts").index_by { |row| row.fetch("id") }
    assert_equal [ active.id, completed.id ].sort, rows.keys.sort
    assert rows.fetch(active.id).fetch("assignable")
    refute rows.fetch(completed.id).fetch("assignable")
    assert_equal "Completed and archived cohorts are read-only.", rows.fetch(completed.id).fetch("blocked_reason")
    refute rows.key?(hidden.id)
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def cohort_for(creator, name:, status: "active")
    Cohort.create!(name: name, status: status, created_by_user: creator)
  end

  def persona_for(creator, assistant_name:)
    CoachPersona.create!(
      name: assistant_name,
      description: "A coach-approved participant experience.",
      draft_config: persona_configuration(assistant_name: assistant_name, coach_name: creator.full_name),
      created_by_user: creator
    )
  end

  def published_persona(creator, assistant_name:)
    persona = persona_for(creator, assistant_name: assistant_name)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: creator)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: nil
    )
    persona.reload
  end

  def patch_assignment(cohort, user, persona_id:, expected_persona_id:)
    patch "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment",
      params: {
        persona_assignment: {
          persona_id: persona_id,
          expected_persona_id: expected_persona_id
        }
      },
      headers: auth_headers(user),
      as: :json
  end

  def delete_assignment(cohort, user, expected_persona_id:)
    delete "/api/v1/admin/cohorts/#{cohort.id}/persona_assignment",
      params: { persona_assignment: { expected_persona_id: expected_persona_id } },
      headers: auth_headers(user),
      as: :json
  end
end
