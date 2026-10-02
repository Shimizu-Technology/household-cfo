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

  test "changing an existing multi-cohort coach to participant rechecks persona compatibility" do
    admin = create_user(role: "admin")
    coach = create_user(role: "coach")
    first = Cohort.create!(name: "Role change first cohort", status: "active", created_by_user: admin)
    second = Cohort.create!(name: "Role change second cohort", status: "active", created_by_user: admin)
    first.cohort_persona_assignment = assignment_for(first, published_persona(admin, "Role change Ari"), admin)
    second.cohort_persona_assignment = assignment_for(second, published_persona(admin, "Role change Bea"), admin)
    coach.cohort_memberships.create!(cohort: first, role: "coach")
    coach.cohort_memberships.create!(cohort: second, role: "coach")

    patch "/api/v1/admin/users/#{coach.id}",
      params: { user: { role: "participant" } },
      headers: auth_headers(admin),
      as: :json

    assert_response :conflict
    assert_equal "persona_assignment_conflict", response.parsed_body.fetch("code")
    assert_equal "coach", coach.reload.role
    assert_equal %w[coach coach], coach.cohort_memberships.order(:id).pluck(:role)
  end

  test "selected workspace update rejects a persona conflict with a retained outside workspace cohort" do
    admin = create_user(role: "admin")
    selected_owner = create_user(role: "coach")
    outside_owner = create_user(role: "coach")
    selected_workspace = CoachWorkspaces::Provisioner.ensure_for!(selected_owner)
    outside_workspace = CoachWorkspaces::Provisioner.ensure_for!(outside_owner)
    existing_selected = workspace_cohort(selected_owner, selected_workspace, "Existing selected cohort")
    requested_selected = workspace_cohort(selected_owner, selected_workspace, "Conflicting selected cohort", persona_name: "Selected Ari")
    outside = workspace_cohort(outside_owner, outside_workspace, "Retained outside cohort", persona_name: "Outside Bea")
    participant = create_user(role: "participant")
    participant.cohort_memberships.create!(cohort: existing_selected, role: "participant")
    participant.cohort_memberships.create!(cohort: outside, role: "participant")

    patch "/api/v1/admin/users/#{participant.id}",
      params: { user: { role: "participant", cohort_ids: [ requested_selected.id ] } },
      headers: workspace_auth_headers(admin, selected_workspace),
      as: :json

    assert_response :conflict
    assert_equal "persona_assignment_conflict", response.parsed_body.fetch("code")
    assert_equal [ existing_selected.id, outside.id ].sort, participant.reload.cohort_ids.sort
  end

  test "selected workspace update accepts the compatible union with retained outside cohorts" do
    admin = create_user(role: "admin")
    selected_owner = create_user(role: "coach")
    outside_owner = create_user(role: "coach")
    selected_workspace = CoachWorkspaces::Provisioner.ensure_for!(selected_owner)
    outside_workspace = CoachWorkspaces::Provisioner.ensure_for!(outside_owner)
    existing_selected = workspace_cohort(selected_owner, selected_workspace, "Compatible existing selected")
    requested_selected = workspace_cohort(selected_owner, selected_workspace, "Compatible requested selected")
    outside = workspace_cohort(outside_owner, outside_workspace, "Compatible retained outside", persona_name: "Outside-only voice")
    participant = create_user(role: "participant")
    participant.cohort_memberships.create!(cohort: existing_selected, role: "participant")
    participant.cohort_memberships.create!(cohort: outside, role: "participant")

    patch "/api/v1/admin/users/#{participant.id}",
      params: { user: { role: "participant", cohort_ids: [ requested_selected.id ] } },
      headers: workspace_auth_headers(admin, selected_workspace),
      as: :json

    assert_response :success
    assert_equal [ requested_selected.id, outside.id ].sort, participant.reload.cohort_ids.sort
  end

  test "selected workspace existing user attach rejects a conflict with the outside workspace persona" do
    admin = create_user(role: "admin")
    selected_owner = create_user(role: "coach")
    outside_owner = create_user(role: "coach")
    selected_workspace = CoachWorkspaces::Provisioner.ensure_for!(selected_owner)
    outside_workspace = CoachWorkspaces::Provisioner.ensure_for!(outside_owner)
    requested_selected = workspace_cohort(selected_owner, selected_workspace, "Attach conflict selected", persona_name: "Attach Ari")
    outside = workspace_cohort(outside_owner, outside_workspace, "Attach conflict outside", persona_name: "Attach Bea")
    participant = create_user(role: "participant")
    participant.cohort_memberships.create!(cohort: outside, role: "participant")

    post "/api/v1/admin/users",
      params: { user: { email: participant.email, role: "participant", cohort_id: requested_selected.id } },
      headers: workspace_auth_headers(admin, selected_workspace),
      as: :json

    assert_response :conflict
    assert_equal "persona_assignment_conflict", response.parsed_body.fetch("code")
    assert_equal [ outside.id ], participant.reload.cohort_ids
  end

  test "selected workspace existing user attach accepts a compatible cross workspace union" do
    admin = create_user(role: "admin")
    selected_owner = create_user(role: "coach")
    outside_owner = create_user(role: "coach")
    selected_workspace = CoachWorkspaces::Provisioner.ensure_for!(selected_owner)
    outside_workspace = CoachWorkspaces::Provisioner.ensure_for!(outside_owner)
    requested_selected = workspace_cohort(selected_owner, selected_workspace, "Compatible attach selected")
    outside = workspace_cohort(outside_owner, outside_workspace, "Compatible attach outside", persona_name: "Compatible outside voice")
    participant = create_user(role: "participant")
    participant.cohort_memberships.create!(cohort: outside, role: "participant")

    post "/api/v1/admin/users",
      params: { user: { email: participant.email, role: "participant", cohort_id: requested_selected.id } },
      headers: workspace_auth_headers(admin, selected_workspace),
      as: :json

    assert_response :success
    assert_equal [ requested_selected.id, outside.id ].sort, participant.reload.cohort_ids.sort
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

  def workspace_cohort(owner, workspace, name, persona_name: nil)
    cohort = Cohort.create!(name: name, status: "active", created_by_user: owner, coach_workspace: workspace)
    assignment_for(cohort, published_persona(owner, persona_name), owner) if persona_name
    cohort
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_auth_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
