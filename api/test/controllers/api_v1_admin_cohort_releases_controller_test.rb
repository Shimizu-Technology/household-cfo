# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCohortReleasesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "readiness and bounded history are privacy safe and independent of mutation authority" do
    owner, cohort, = governed_components
    viewer = persona_user
    cohort.coach_workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    get endpoint(cohort), headers: workspace_headers(owner, cohort.coach_workspace)
    assert_response :success
    owner_payload = response.parsed_body.fetch("cohort_release_studio")
    assert owner_payload.dig("readiness", "ready")
    assert owner_payload.dig("readiness", "seal_needed")
    assert_equal 4, owner_payload.dig("readiness", "checks").length
    assert_equal false, owner_payload.dig("runtime_truth", "participant_runtime_changed")
    assert_equal 0, owner_payload.dig("cohort", "participant_count")
    assert owner_payload.dig("permissions", "seal")

    get endpoint(cohort), headers: workspace_headers(viewer, cohort.coach_workspace)
    assert_response :success
    viewer_payload = response.parsed_body.fetch("cohort_release_studio")
    assert viewer_payload.dig("readiness", "ready")
    assert_equal false, viewer_payload.dig("permissions", "seal")
    assert_nil viewer_payload.dig("readiness", "candidate", "config")
    refute_includes response.body, "sample_reply"
    refute_includes response.body, "draft_config"
  end

  test "seal requires explicit idempotency and returns 201 then 200 replay" do
    owner, cohort, = governed_components
    headers = workspace_headers(owner, cohort.coach_workspace)
    payload = seal_payload(cohort)

    post endpoint(cohort), params: { release: payload }, headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "cohort_release_invalid", response.parsed_body.fetch("code")

    request_headers = headers.merge("Idempotency-Key" => "api-seal-1")
    post endpoint(cohort), params: { release: payload }, headers: request_headers, as: :json
    assert_response :created
    assert_equal false, response.parsed_body.fetch("replayed")
    release_id = response.parsed_body.dig("release", "id")
    assert_equal "cohort.release.seal", response.parsed_body.dig("operation_execution", "operation_key")
    assert_equal false, response.parsed_body.dig("cohort_release_studio", "runtime_truth", "participant_runtime_changed")

    post endpoint(cohort), params: { release: payload }, headers: request_headers, as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("replayed")
    assert_equal release_id, response.parsed_body.dig("release", "id")
  end

  test "platform admin can operate without workspace header while cross workspace coaches see not found" do
    owner, cohort, = governed_components
    admin = persona_user(role: "admin")
    outsider = persona_user
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(outsider)
    payload = seal_payload(cohort)

    post endpoint(cohort), params: { release: payload },
      headers: auth_headers(admin).merge("Idempotency-Key" => "admin-global-seal"), as: :json
    assert_response :created
    assert_equal "platform_admin", response.parsed_body.dig("operation_execution", "actor_role_snapshot")

    get endpoint(cohort), headers: workspace_headers(outsider, other_workspace)
    assert_response :not_found
    post endpoint(cohort), params: { release: payload },
      headers: workspace_headers(outsider, other_workspace).merge("Idempotency-Key" => "cross-workspace"), as: :json
    assert_response :not_found
  end

  test "same bundle with a new request is a stable 409 no-op" do
    owner, cohort, = governed_components
    headers = workspace_headers(owner, cohort.coach_workspace)
    payload = seal_payload(cohort)

    post endpoint(cohort), params: { release: payload },
      headers: headers.merge("Idempotency-Key" => "first-seal"), as: :json
    assert_response :created
    post endpoint(cohort), params: { release: payload },
      headers: headers.merge("Idempotency-Key" => "duplicate-seal"), as: :json
    assert_response :conflict
    assert_equal "cohort_release_noop", response.parsed_body.fetch("code")
  end

  test "restore pins the source and latest records and creates new immutable evidence" do
    owner, cohort, = governed_components
    first_input = seal_payload(cohort)
    first = run_seal(cohort, owner, first_input, "restore-source").release
    publish_changed_experience(cohort, owner)
    second_input = seal_payload(cohort)
    second = run_seal(cohort, owner, second_input, "restore-current").release

    payload = {
      expected_latest_release_id: second.id,
      source_bundle_digest: first.bundle_digest,
      source_persona_version_id: first.coach_persona_version_id,
      source_experience_version_id: first.cohort_experience_version_id
    }
    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: payload },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "restore-first"), as: :json
    assert_response :created
    assert_equal "restore", response.parsed_body.dig("release", "event_type")
    assert_equal first.id, response.parsed_body.dig("release", "source_release_id")
    assert_equal first.bundle_digest, response.parsed_body.dig("release", "bundle_digest")
    assert_equal 3, cohort.reload.cohort_releases.count
    assert_equal 3, cohort.coach_operation_executions.count

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: payload },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "restore-noop"), as: :json
    assert_response :conflict
    assert_equal "cohort_release_noop", response.parsed_body.fetch("code")
  end

  private

  def governed_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Release API #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    persona = create_persona(creator: owner, name: "Release API persona #{SecureRandom.hex(4)}", workspace: workspace)
    persona_version = publish_persona(persona, actor: owner)
    assignment = CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_workspace: workspace,
      coach_persona: persona,
      coach_persona_version: persona_version,
      assigned_by_user: owner
    )
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    experience_version = publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: nil
    )
    [ owner, cohort, assignment, persona_version, experience_version ]
  end

  def publish_changed_experience(cohort, owner)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: CohortExperience::Schema::LEGACY_CONFIG, last_edited_by_user: owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: configuration.current_published_version_id
    )
  end

  def seal_payload(cohort)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort.reload, strict: true).call
    {
      expected_assignment_id: candidate.assignment.id,
      expected_bundle_digest: candidate.bundle_digest,
      expected_experience_version_id: candidate.experience_version.id,
      expected_latest_release_id: cohort.cohort_releases.order(release_number: :desc).pick(:id),
      expected_persona_version_id: candidate.persona_version.id,
      expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      expected_tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
  end

  def run_seal(cohort, owner, input, request_key)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal",
      operation_version: 1,
      input: input,
      request_key: request_key
    )
  end

  def endpoint(cohort)
    "/api/v1/admin/cohorts/#{cohort.id}/releases"
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
