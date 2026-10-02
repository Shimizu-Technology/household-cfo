# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminPersonaMembershipCompatibilityTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "inviting a participant to cohorts with different personas is rejected atomically" do
    admin = persona_user(role: "admin")
    first = assigned_cohort(admin, cohort_name: "Invite conflict one", assistant_name: "Invite assistant one")
    second = assigned_cohort(admin, cohort_name: "Invite conflict two", assistant_name: "Invite assistant two")

    post "/api/v1/admin/users",
      params: {
        user: {
          email: "conflicting-invite@example.com",
          role: "participant",
          cohort_ids: [ first.id, second.id ],
          send_invitation_email: false
        }
      },
      headers: auth_headers(admin),
      as: :json

    assert_response :conflict
    assert_equal "persona_assignment_conflict", response.parsed_body.fetch("code")
    assert_equal "This participant would receive different personas from their cohorts.", response.parsed_body.fetch("error")
    assert_nil User.find_by(email: "conflicting-invite@example.com")
  end

  test "inviting a participant to cohorts sharing one persona remains supported" do
    admin = persona_user(role: "admin")
    persona = published_persona(admin, assistant_name: "Shared invite assistant")
    first = cohort_for(admin, name: "Shared invite one")
    second = cohort_for(admin, name: "Shared invite two")
    CohortPersonaAssignment.create!(cohort: first, coach_persona: persona, assigned_by_user: admin)
    CohortPersonaAssignment.create!(cohort: second, coach_persona: persona, assigned_by_user: admin)

    post "/api/v1/admin/users",
      params: {
        user: {
          email: "shared-invite@example.com",
          role: "participant",
          cohort_ids: [ first.id, second.id ],
          send_invitation_email: false
        }
      },
      headers: auth_headers(admin),
      as: :json

    assert_response :created
    participant = User.find_by!(email: "shared-invite@example.com")
    assert_equal [ first.id, second.id ].sort, participant.cohort_ids.sort
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def cohort_for(creator, name:)
    Cohort.create!(name: name, status: "active", created_by_user: creator)
  end

  def assigned_cohort(creator, cohort_name:, assistant_name:)
    persona = published_persona(creator, assistant_name: assistant_name)
    cohort = cohort_for(creator, name: cohort_name)
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: creator)
    cohort
  end

  def published_persona(creator, assistant_name:)
    persona = CoachPersona.create!(
      name: assistant_name,
      draft_config: persona_configuration(assistant_name: assistant_name, coach_name: creator.full_name),
      created_by_user: creator
    )
    publish_persona(persona, actor: creator)
    persona.reload
  end
end
