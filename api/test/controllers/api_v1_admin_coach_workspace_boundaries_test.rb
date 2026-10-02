# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCoachWorkspaceBoundariesTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "explicit workspace selection isolates personas cohorts and content for a workspace member" do
    first_owner = persona_user
    second_owner = persona_user
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    first_persona = create_persona(creator: first_owner, name: "First workspace assistant")
    second_persona = create_persona(creator: second_owner, name: "Second workspace assistant")
    first_cohort = cohort_for(first_owner, name: "First workspace cohort")
    second_cohort = cohort_for(second_owner, name: "Second workspace cohort")
    first_item = approved_content_item(owner: first_owner, title: "First workspace method")
    second_item = approved_content_item(owner: second_owner, title: "Second workspace method")

    get "/api/v1/admin/personas", headers: workspace_headers(first_owner, first_workspace)
    assert_response :success
    assert_equal [ first_persona.id ], response.parsed_body.fetch("personas").pluck("id")

    get "/api/v1/admin/personas/#{second_persona.id}", headers: workspace_headers(first_owner, first_workspace)
    assert_response :not_found

    get "/api/v1/admin/personas/assignable_cohorts", headers: workspace_headers(first_owner, first_workspace)
    assert_response :success
    assert_equal [ first_cohort.id ], response.parsed_body.fetch("cohorts").pluck("id")
    refute_includes response.body, second_cohort.name

    get "/api/v1/admin/content_items", headers: workspace_headers(first_owner, first_workspace)
    assert_response :success
    assert_equal [ first_item.id ], response.parsed_body.fetch("items").pluck("id")
    refute_includes response.body, second_item.title
  end

  test "workspace role permissions separate editing reviewing and read only access" do
    owner = persona_user
    editor = persona_user
    reviewer = persona_user
    viewer = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")
    item = CoachContentItem.create!(
      title: "Reviewed workspace guidance",
      scope: "coach",
      kind: "guidance",
      draft_content: "Ask for the missing household fact before coaching.",
      created_by_user: owner,
      coach_workspace: workspace
    )
    persona = create_persona(creator: owner, name: "Reviewed workspace assistant")
    publish_persona(persona, actor: owner)

    patch "/api/v1/admin/content_items/#{item.id}",
      params: { item: { draft_revision: item.draft_revision, draft_content: "Ask one exact household question before coaching." } },
      headers: workspace_headers(editor, workspace), as: :json
    assert_response :success

    post "/api/v1/admin/content_items/#{item.id}/approve",
      params: { item: { draft_revision: item.reload.draft_revision, draft_digest: item.draft_digest } },
      headers: workspace_headers(editor, workspace), as: :json
    assert_response :not_found

    post "/api/v1/admin/content_items/#{item.id}/approve",
      params: { item: { draft_revision: item.reload.draft_revision, draft_digest: item.draft_digest } },
      headers: workspace_headers(reviewer, workspace), as: :json
    assert_response :success

    patch "/api/v1/admin/content_items/#{item.id}",
      params: { item: { draft_revision: item.reload.draft_revision, draft_content: "Reviewer rewrite" } },
      headers: workspace_headers(reviewer, workspace), as: :json
    assert_response :not_found

    get "/api/v1/admin/content_items", headers: workspace_headers(viewer, workspace)
    assert_response :success
    serialized = response.parsed_body.fetch("items").sole
    assert_equal false, serialized.fetch("editable")
    assert_equal false, serialized.fetch("approvable")
    assert_nil serialized.fetch("draft_content")

    get "/api/v1/admin/personas/#{persona.id}", headers: workspace_headers(editor, workspace)
    assert_response :success
    assert_equal({ "read" => true, "edit" => true, "publish" => false, "assign" => false, "archive" => true, "restore" => false },
      response.parsed_body.dig("persona", "permissions"))

    get "/api/v1/admin/personas/#{persona.id}", headers: workspace_headers(reviewer, workspace)
    assert_response :success
    assert_equal false, response.parsed_body.dig("persona", "permissions", "edit")
    assert_equal true, response.parsed_body.dig("persona", "permissions", "publish")
    assert_equal true, response.parsed_body.dig("persona", "permissions", "assign")
  end

  test "cross workspace persona assignments are rejected by models and database constraints" do
    first_owner = persona_user
    second_owner = persona_user
    persona = create_persona(creator: first_owner, name: "First boundary persona")
    publish_persona(persona, actor: first_owner)
    cohort = cohort_for(second_owner, name: "Second boundary cohort")

    assignment = CohortPersonaAssignment.new(
      cohort: cohort,
      coach_persona: persona,
      assigned_by_user: first_owner,
      coach_workspace: cohort.coach_workspace
    )
    refute assignment.valid?
    assert_includes assignment.errors[:coach_persona], "must belong to the same coach workspace"

    assert_raises(ActiveRecord::InvalidForeignKey) do
      CohortPersonaAssignment.insert!({
        cohort_id: cohort.id,
        coach_persona_id: persona.id,
        coach_persona_version_id: persona.current_published_version_id,
        assigned_by_user_id: first_owner.id,
        coach_workspace_id: cohort.coach_workspace_id,
        created_at: Time.current,
        updated_at: Time.current
      })
    end
  end

  test "persona assignment database requires the published version to belong to its persona" do
    owner = persona_user
    first = create_persona(
      creator: owner,
      name: "First version boundary persona",
      config: persona_configuration(assistant_name: "First version boundary persona")
    )
    second = create_persona(
      creator: owner,
      name: "Second version boundary persona",
      config: persona_configuration(assistant_name: "Second version boundary persona")
    )
    publish_persona(first, actor: owner)
    publish_persona(second, actor: owner)
    cohort = cohort_for(owner, name: "Version boundary cohort")

    assignment = CohortPersonaAssignment.new(
      cohort: cohort,
      coach_persona: first,
      coach_persona_version: second.current_published_version,
      assigned_by_user: owner,
      coach_workspace: cohort.coach_workspace
    )
    refute assignment.valid?
    assert_includes assignment.errors[:coach_persona_version], "must be the persona's current published version"

    assert_raises(ActiveRecord::InvalidForeignKey) do
      CohortPersonaAssignment.insert!({
        cohort_id: cohort.id,
        coach_persona_id: first.id,
        coach_persona_version_id: second.current_published_version_id,
        assigned_by_user_id: owner.id,
        coach_workspace_id: cohort.coach_workspace_id,
        created_at: Time.current,
        updated_at: Time.current
      })
    end
  end

  test "workspace editors and owners collaborate on sealed phrases while other workspaces stay denied" do
    owner = persona_user
    editor = persona_user
    outsider = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    outsider_workspace = CoachWorkspaces::Provisioner.ensure_for!(outsider)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")

    owner_config = persona_configuration(assistant_name: "Owner phrase assistant")
    owner_config["phrases"] = [ persona_phrase_artifact({
      "text" => "Pause and name the number.",
      "meaning" => "The coach's exact prompt before a money decision."
    }, source_user_id: owner.id) ]
    owner_persona = CoachPersona.create!(
      name: "Owner phrase assistant",
      draft_config: owner_config,
      created_by_user: owner,
      coach_workspace: workspace
    )
    owner_artifact_id = owner_persona.draft_config.dig("phrases", 0, "artifact_id")
    editor_draft = owner_persona.draft_config.deep_dup
    editor_draft["phrases"][0]["meaning"] = "The workspace editor's reviewed coaching prompt."

    patch "/api/v1/admin/personas/#{owner_persona.id}",
      params: { persona: { draft_revision: owner_persona.draft_revision, draft_config: editor_draft } },
      headers: workspace_headers(editor, workspace), as: :json

    assert_response :success
    editor_artifact = owner_persona.reload.draft_config.fetch("phrases").sole
    assert_equal owner_artifact_id, editor_artifact.fetch("artifact_id")
    assert_equal editor.id, editor_artifact.fetch("source_user_id")
    assert_equal "The workspace editor's reviewed coaching prompt.", editor_artifact.fetch("meaning")

    editor_config = persona_configuration(assistant_name: "Editor phrase assistant")
    editor_config["phrases"] = [ persona_phrase_artifact({
      "text" => "Choose the next useful step.",
      "meaning" => "The editor's exact transition into action."
    }, source_user_id: editor.id) ]
    editor_persona = CoachPersona.create!(
      name: "Editor phrase assistant",
      draft_config: editor_config,
      created_by_user: editor,
      coach_workspace: workspace
    )
    owner_draft = editor_persona.draft_config.deep_dup
    owner_draft["phrases"][0]["caution"] = "Use after the household confirms the relevant facts."

    patch "/api/v1/admin/personas/#{editor_persona.id}",
      params: { persona: { draft_revision: editor_persona.draft_revision, draft_config: owner_draft } },
      headers: workspace_headers(owner, workspace), as: :json

    assert_response :success
    assert_equal owner.id, editor_persona.reload.draft_config.dig("phrases", 0, "source_user_id")

    patch "/api/v1/admin/personas/#{owner_persona.id}",
      params: { persona: { draft_revision: owner_persona.draft_revision, draft_config: editor_draft } },
      headers: workspace_headers(outsider, outsider_workspace), as: :json

    assert_response :not_found
    assert_equal editor.id, owner_persona.reload.draft_config.dig("phrases", 0, "source_user_id")
  end

  test "auth exposes accessible workspaces and honors an authorized active selection" do
    coach = persona_user
    collaborator = persona_user
    owned = CoachWorkspaces::Provisioner.ensure_for!(coach)
    shared = CoachWorkspaces::Provisioner.ensure_for!(collaborator)
    shared.coach_workspace_memberships.create!(user: coach, role: "reviewer")

    get "/api/v1/auth/me", headers: workspace_headers(coach, shared)

    assert_response :success
    assert_equal shared.id, response.parsed_body.dig("user", "active_coach_workspace", "id")
    assert_equal [ owned.id, shared.id ].sort, response.parsed_body.dig("user", "coach_workspaces").pluck("id").sort
    selected = response.parsed_body.dig("user", "coach_workspaces").find { |workspace| workspace.fetch("id") == shared.id }
    assert_equal "reviewer", selected.fetch("membership_role")
  end

  test "a workspace header cannot select a tenant the coach has not joined" do
    coach = persona_user
    other = persona_user
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other)

    get "/api/v1/admin/personas", headers: workspace_headers(coach, other_workspace)

    assert_response :not_found
  end

  test "malformed workspace headers fail closed without provisioning a default" do
    admin = persona_user(role: "admin")
    authorization = "Bearer test_token:#{admin.clerk_id}:#{admin.email}:#{admin.first_name}:#{admin.last_name}"

    [ "abc", "0", "-1", "010", "0x10" ].each do |requested_id|
      assert_no_difference -> { CoachWorkspace.count }, "header #{requested_id.inspect} provisioned a workspace" do
        get "/api/v1/admin/personas", headers: {
          "Authorization" => authorization,
          "X-Coach-Workspace-Id" => requested_id
        }
      end
      assert_response :not_found
    end
  end

  test "platform mode never silently chooses a workspace for workspace-owned creates" do
    admin = persona_user(role: "admin")
    headers = { "Authorization" => "Bearer test_token:#{admin.clerk_id}:#{admin.email}:#{admin.first_name}:#{admin.last_name}" }

    assert_no_difference -> { CoachPersona.count } do
      post "/api/v1/admin/personas", params: { persona: { name: "Hidden tenant assistant" } }, headers: headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    assert_no_difference -> { Cohort.count } do
      post "/api/v1/admin/cohorts", params: { cohort: { name: "Hidden tenant cohort", status: "draft" } }, headers: headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    assert_no_difference -> { CoachContentItem.count } do
      post "/api/v1/admin/content_items", params: {
        item: { title: "Hidden tenant content", scope: "coach", kind: "guidance", draft_content: "Choose one next step." }
      }, headers: headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    assert_no_difference -> { CoachContentPack.count } do
      post "/api/v1/admin/content_packs", params: {
        pack: { name: "Hidden tenant pack", scope: "coach", pack_kind: "coaching_method", item_version_ids: [] }
      }, headers: headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    assert_no_difference -> { CoachContentSource.count } do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "hidden-tenant.txt",
        content_type: "text/plain",
        byte_size: 5,
        checksum_sha256: Digest::SHA256.hexdigest("guide"),
        upload_request_id: SecureRandom.uuid,
        scope: "coach"
      }, headers: headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    assert_difference -> { CoachContentItem.where(scope: "platform").count }, 1 do
      post "/api/v1/admin/content_items", params: {
        item: { title: "Explicit platform content", scope: "platform", kind: "guidance", draft_content: "Choose one next step." }
      }, headers: headers, as: :json
    end
    assert_response :created
  end

  test "omitting the workspace header resolves a coach to one authorized default workspace" do
    coach = persona_user
    collaborator = persona_user
    default_workspace = CoachWorkspaces::Provisioner.ensure_for!(coach)
    shared_workspace = CoachWorkspaces::Provisioner.ensure_for!(collaborator)
    shared_workspace.coach_workspace_memberships.create!(user: coach, role: "editor")
    default_persona = create_persona(creator: coach, name: "Default workspace assistant")
    shared_persona = create_persona(
      creator: coach,
      name: "Shared workspace assistant",
      config: persona_configuration(assistant_name: "Shared workspace assistant"),
      workspace: shared_workspace
    )

    get "/api/v1/admin/personas", headers: {
      "Authorization" => "Bearer test_token:#{coach.clerk_id}:#{coach.email}:#{coach.first_name}:#{coach.last_name}"
    }

    assert_response :success
    assert_equal [ default_persona.id ], response.parsed_body.fetch("personas").pluck("id")
    refute_includes response.body, shared_persona.name
    assert_equal default_workspace.id, CoachWorkspaces::Resolver.new(user: coach).call.id
  end

  private

  def workspace_headers(user, workspace)
    {
      "Authorization" => "Bearer test_token:#{user.clerk_id}:#{user.email}:#{user.first_name}:#{user.last_name}",
      "X-Coach-Workspace-Id" => workspace.id.to_s
    }
  end
end
