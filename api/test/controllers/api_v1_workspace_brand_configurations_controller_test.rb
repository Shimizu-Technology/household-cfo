# frozen_string_literal: true

require "test_helper"

class ApiV1WorkspaceBrandConfigurationsControllerTest < ActionDispatch::IntegrationTest
  test "owner editor reviewer and viewer receive exact brand permissions" do
    owner, editor, reviewer, viewer = Array.new(4) { create_user("coach") }
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    expected = {
      owner => { "edit" => true, "preview" => true, "publish" => true, "rollback" => true },
      editor => { "edit" => true, "preview" => true, "publish" => false, "rollback" => false },
      reviewer => { "edit" => false, "preview" => true, "publish" => true, "rollback" => true },
      viewer => { "edit" => false, "preview" => false, "publish" => false, "rollback" => false }
    }
    expected.each do |user, permissions|
      get endpoint, headers: workspace_headers(user, workspace)
      assert_response :success
      assert_equal permissions, response.parsed_body.dig("brand_configuration", "permissions")
    end

    patch endpoint, params: brand_update(workspace.workspace_brand_configuration, "Editor Product"),
      headers: workspace_headers(editor, workspace), as: :json
    assert_response :success

    patch endpoint, params: brand_update(workspace.workspace_brand_configuration.reload, "Reviewer Product"),
      headers: workspace_headers(reviewer, workspace), as: :json
    assert_response :not_found

    post "#{endpoint}/preview", params: {
      brand_configuration: { draft_revision: workspace.workspace_brand_configuration.reload.draft_revision }
    }, headers: workspace_headers(reviewer, workspace), as: :json
    assert_response :success
    digest = response.parsed_body.dig("preview", "digest")
    initial_version = workspace.workspace_brand_configuration.current_published_version

    post "#{endpoint}/publish", params: {
      brand_configuration: {
        draft_revision: workspace.workspace_brand_configuration.draft_revision,
        preview_digest: digest,
        expected_published_version_id: initial_version.id
      }
    }, headers: workspace_headers(reviewer, workspace).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    reviewer_version_id = response.parsed_body.dig("published_version", "id")

    post "#{endpoint}/versions/#{initial_version.id}/rollback", params: {
      brand_configuration: {
        draft_revision: workspace.workspace_brand_configuration.reload.draft_revision,
        expected_published_version_id: reviewer_version_id
      }
    }, headers: workspace_headers(reviewer, workspace).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert_equal reviewer.id, workspace.workspace_brand_configuration.reload.last_edited_by_user_id
  end

  test "save preview publish and restore preserve immutable history and replay safely" do
    owner = create_user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    configuration = workspace.workspace_brand_configuration
    initial_version = configuration.current_published_version

    patch endpoint, params: brand_update(configuration, "Coach Morgan Money"),
      headers: workspace_headers(owner, workspace), as: :json
    assert_response :success
    revision = response.parsed_body.dig("brand_configuration", "draft_revision")

    post "#{endpoint}/preview", params: {
      brand_configuration: { draft_revision: revision }
    }, headers: workspace_headers(owner, workspace), as: :json
    assert_response :success
    digest = response.parsed_body.dig("preview", "digest")

    publish_key = SecureRandom.uuid
    publish_params = {
      brand_configuration: {
        draft_revision: revision,
        preview_digest: digest,
        expected_published_version_id: initial_version.id
      }
    }
    post "#{endpoint}/publish", params: publish_params,
      headers: workspace_headers(owner, workspace).merge("Idempotency-Key" => publish_key), as: :json
    assert_response :success
    published_id = response.parsed_body.dig("published_version", "id")
    assert_equal "Coach Morgan Money", response.parsed_body.dig("published_version", "config", "product_name")

    post "#{endpoint}/publish", params: publish_params,
      headers: workspace_headers(owner, workspace).merge("Idempotency-Key" => publish_key), as: :json
    assert_response :success
    assert_equal published_id, response.parsed_body.dig("published_version", "id")
    assert_equal 2, configuration.versions.count

    rollback_key = SecureRandom.uuid
    post "#{endpoint}/versions/#{initial_version.id}/rollback", params: {
      brand_configuration: {
        draft_revision: configuration.reload.draft_revision,
        expected_published_version_id: published_id
      }
    }, headers: workspace_headers(owner, workspace).merge("Idempotency-Key" => rollback_key), as: :json
    assert_response :success
    restored = response.parsed_body.fetch("published_version")
    assert_equal "Household CFO", restored.dig("config", "product_name")
    assert_equal initial_version.id, restored.dig("restored_from_version", "id")
    assert_equal 3, configuration.versions.count
  end

  test "publish and restore reject oversized idempotency keys without changing history" do
    owner = create_user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    configuration = workspace.workspace_brand_configuration
    initial_version = configuration.current_published_version

    patch endpoint, params: brand_update(configuration, "Bounded Key Brand"),
      headers: workspace_headers(owner, workspace), as: :json
    assert_response :success

    post "#{endpoint}/preview", params: {
      brand_configuration: { draft_revision: configuration.reload.draft_revision }
    }, headers: workspace_headers(owner, workspace), as: :json
    assert_response :success

    post "#{endpoint}/publish", params: {
      brand_configuration: {
        draft_revision: configuration.draft_revision,
        preview_digest: response.parsed_body.dig("preview", "digest"),
        expected_published_version_id: initial_version.id
      }
    }, headers: workspace_headers(owner, workspace).merge("Idempotency-Key" => "k" * 256), as: :json
    assert_response :unprocessable_entity
    assert_equal "idempotency_key_invalid", response.parsed_body.fetch("code")

    post "#{endpoint}/versions/#{initial_version.id}/rollback", params: {
      brand_configuration: {
        draft_revision: configuration.reload.draft_revision,
        expected_published_version_id: initial_version.id
      }
    }, headers: workspace_headers(owner, workspace).merge("Idempotency-Key" => "r" * 256), as: :json
    assert_response :unprocessable_entity
    assert_equal "idempotency_key_invalid", response.parsed_body.fetch("code")
    assert_equal 1, configuration.versions.count
    assert_equal 1, configuration.publication_events.count
  end

  test "stale inaccessible malformed and cross workspace requests fail closed" do
    owner = create_user("coach")
    outsider = create_user("coach")
    participant = create_user("participant")
    admin = create_user("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    outsider_workspace = CoachWorkspaces::Provisioner.ensure_for!(outsider)

    patch endpoint, params: {
      brand_configuration: { draft_revision: 999, draft_config: Branding::Schema::DEFAULT_CONFIG }
    }, headers: workspace_headers(owner, workspace), as: :json
    assert_response :conflict
    assert_equal "brand_draft_conflict", response.parsed_body.fetch("code")

    invalid = Branding::Schema::DEFAULT_CONFIG.deep_dup
    invalid["colors"]["text"] = "#ffffff"
    patch endpoint, params: {
      brand_configuration: { draft_revision: 1, draft_config: invalid }
    }, headers: workspace_headers(owner, workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "brand_configuration_invalid", response.parsed_body.fetch("code")

    get endpoint, headers: workspace_headers(outsider, outsider_workspace).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
    assert_response :not_found

    get endpoint, headers: auth_headers(participant)
    assert_response :forbidden

    get endpoint, headers: auth_headers(admin)
    assert_response :not_found
  end

  test "public brand endpoint exposes published presentation only and uses a neutral unknown-host fallback" do
    owner = create_user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    now = Time.current
    workspace.coach_workspace_domains.create!(
      hostname: "morgan-money.example.com",
      kind: "custom",
      status: "active",
      is_primary: true,
      verified_at: now,
      activated_at: now,
      created_by_user: owner,
      updated_by_user: owner
    )

    get "/api/public/brand", params: { hostname: "morgan-money.example.com" }
    assert_response :success
    assert_equal "Household CFO", response.parsed_body.dig("brand", "product_name")
    assert_equal workspace.slug, response.parsed_body.dig("workspace", "slug")
    refute response.body.include?(owner.email)

    get "/api/public/brand", params: { hostname: "unknown.example.com" }
    assert_response :not_found
    assert_equal false, response.parsed_body.fetch("available")
    assert_equal "VERA", response.parsed_body.dig("brand", "product_name")
    assert_nil response.parsed_body.fetch("workspace")
  end

  test "authenticated participant runtime is constrained by the exact brand hostname" do
    first_owner = create_user("coach")
    second_owner = create_user("coach")
    participant = create_user("participant")
    other_participant = create_user("participant")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    first_cohort = Cohort.create!(name: "First branded runtime", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    second_cohort = Cohort.create!(name: "Second branded runtime", status: "active", created_by_user: second_owner, coach_workspace: second_workspace)
    first_cohort.cohort_memberships.create!(user: participant, role: "participant")
    second_cohort.cohort_memberships.create!(user: participant, role: "participant")
    second_cohort.cohort_memberships.create!(user: other_participant, role: "participant")
    now = Time.current
    first_workspace.coach_workspace_domains.create!(
      hostname: "first-runtime.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: first_owner, updated_by_user: first_owner
    )
    second_workspace.coach_workspace_domains.create!(
      hostname: "second-runtime.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: second_owner, updated_by_user: second_owner
    )

    get "/api/v1/workspace", headers: auth_headers(participant).merge(
      "Origin" => "https://first-runtime.example.com",
      "X-Brand-Hostname" => "first-runtime.example.com"
    )
    assert_response :success
    assert_equal first_cohort.id, response.parsed_body.dig("workspace", "cohort", "id")

    get "/api/v1/workspace", headers: auth_headers(first_owner).merge(
      "Origin" => "https://first-runtime.example.com",
      "X-Brand-Hostname" => "first-runtime.example.com"
    )
    assert_response :success
    assert_nil response.parsed_body.dig("workspace", "cohort")

    get "/api/v1/workspace", headers: auth_headers(participant).merge("Origin" => "https://first-runtime.example.com")
    assert_response :unprocessable_entity
    assert_equal "This coaching program link is unavailable.", response.parsed_body.fetch("error")

    get "/api/v1/workspace", headers: auth_headers(participant).merge(
      "Origin" => "https://first-runtime.example.com",
      "X-Brand-Hostname" => "second-runtime.example.com"
    )
    assert_response :unprocessable_entity
    assert_equal "This coaching program link is unavailable.", response.parsed_body.fetch("error")

    get "/api/v1/workspace", headers: auth_headers(participant).merge(
      "Origin" => "https://first-runtime.example.com",
      "X-Brand-Hostname" => "first-runtime.example.com",
      "X-Cohort-Id" => second_cohort.id.to_s
    )
    assert_response :unprocessable_entity
    assert_equal "cohort_selection_invalid", response.parsed_body.fetch("code")

    get "/api/v1/workspace", headers: auth_headers(other_participant).merge("X-Brand-Hostname" => "first-runtime.example.com")
    assert_response :unprocessable_entity
    assert_equal "This coaching program link is unavailable.", response.parsed_body.fetch("error")

    get "/api/v1/workspace", headers: auth_headers(participant).merge("X-Brand-Hostname" => "unknown-runtime.example.com")
    assert_response :unprocessable_entity
    assert_equal "This coaching program link is unavailable.", response.parsed_body.fetch("error")
  end

  test "CORS admits only exact active HTTPS workspace domains" do
    owner = create_user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    now = Time.current
    workspace.coach_workspace_domains.create!(
      hostname: "cors-brand.example.com", kind: "custom", status: "active", is_primary: true,
      verified_at: now, activated_at: now, created_by_user: owner, updated_by_user: owner
    )

    options "/api/public/brand", headers: {
      "Origin" => "https://cors-brand.example.com",
      "Access-Control-Request-Method" => "GET"
    }
    assert_response :success
    assert_equal "https://cors-brand.example.com", response.headers["Access-Control-Allow-Origin"]

    options "/api/public/brand", headers: {
      "Origin" => "https://evil-cors-brand.example.com",
      "Access-Control-Request-Method" => "GET"
    }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  private

  def endpoint
    "/api/v1/admin/brand"
  end

  def brand_update(configuration, product_name)
    config = configuration.draft_config.deep_dup
    config["product_name"] = product_name
    config["short_name"] = product_name.first(32)
    { brand_configuration: { draft_revision: configuration.draft_revision, draft_config: config } }
  end

  def create_user(role)
    User.create!(
      clerk_id: "brand_controller_#{SecureRandom.hex(7)}",
      email: "brand-controller-#{SecureRandom.hex(7)}@example.com",
      first_name: "Morgan",
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
