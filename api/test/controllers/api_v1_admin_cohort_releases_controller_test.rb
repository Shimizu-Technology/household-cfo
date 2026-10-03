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
    assert_equal 5, owner_payload.dig("readiness", "checks").length
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

    publish_changed_experience(cohort, owner)
    run_seal(cohort, owner, seal_payload(cohort), "api-seal-2")
    post endpoint(cohort), params: { release: payload }, headers: request_headers, as: :json
    assert_response :success
    replay_payload = response.parsed_body
    history_release = replay_payload.dig("cohort_release_studio", "releases").find do |release|
      release.fetch("id") == release_id
    end
    assert_equal history_release, replay_payload.fetch("release")

    cohort.coach_workspace.coach_workspace_memberships.find_by!(user: owner).update!(role: "viewer")
    post endpoint(cohort), params: { release: payload }, headers: request_headers, as: :json
    assert_response :forbidden
    assert_equal "cohort_release_forbidden", response.parsed_body.fetch("code")
  end

  test "historical v1 seal retries replay under their stored contract and changed input conflicts" do
    owner, cohort, = governed_components
    request_key = "historical-v1-seal"
    release, execution = create_historical_v1_operation!(owner, cohort, request_key: request_key)
    legacy_payload = execution.normalized_input.symbolize_keys
    headers = workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => request_key)

    post endpoint(cohort), params: { release: legacy_payload }, headers: headers, as: :json
    assert_response :success
    assert response.parsed_body.fetch("replayed")
    assert_equal 1, response.parsed_body.dig("operation_execution", "operation_version")
    assert_equal CohortReleases::Contract::V1_SCHEMA, response.parsed_body.dig("release", "manifest_schema")
    assert_equal release.id, response.parsed_body.dig("release", "id")

    post endpoint(cohort), params: {
      release: legacy_payload.merge(expected_bundle_digest: "f" * 64)
    }, headers: headers, as: :json
    assert_response :conflict
    assert_equal "cohort_release_conflict", response.parsed_body.fetch("code")
    assert_equal 1, cohort.cohort_releases.count
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
    owner, cohort, first, = restore_setup
    payload = restore_payload(cohort, first)
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

  test "historical v1 restore retries replay under their stored contract" do
    owner, cohort, = governed_components
    first, = create_historical_v1_operation!(owner, cohort, request_key: "historical-v1-source")
    publish_changed_experience(cohort, owner)
    run_seal(cohort, owner, seal_payload(cohort), "historical-v1-current")
    request_key = "historical-v1-restore"
    release, execution = create_historical_v1_operation!(
      owner,
      cohort,
      request_key: request_key,
      source_release: first
    )
    legacy_payload = execution.normalized_input.except("source_release_id").symbolize_keys

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: legacy_payload },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => request_key), as: :json

    assert_response :success
    assert response.parsed_body.fetch("replayed")
    assert_equal 1, response.parsed_body.dig("operation_execution", "operation_version")
    assert_equal CohortReleases::Contract::V1_SCHEMA, response.parsed_body.dig("release", "manifest_schema")
    assert_equal release.id, response.parsed_body.dig("release", "id")
    assert_equal 3, cohort.cohort_releases.count
  end

  test "restoring governed v1 evidence promotes it to v2 with the historical Household CFO brand" do
    owner, cohort, = governed_components
    first, = create_historical_v1_operation!(owner, cohort, request_key: "v1-promotion-source")
    publish_changed_experience(cohort, owner)
    run_seal(cohort, owner, seal_payload(cohort), "v1-promotion-current")

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: restore_payload(cohort, first) },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "v1-promotion-restore"),
      as: :json

    assert_response :created
    restored = CohortRelease.find(response.parsed_body.dig("release", "id"))
    assert_equal CohortReleases::Contract::V2_SCHEMA, restored.manifest_schema
    assert_equal "legacy_household_cfo_builtin", restored.brand_mode
    assert_nil restored.workspace_brand_version_id
    assert_equal "Household CFO", restored.brand_snapshot.dig("config", "product_name")
    assert_equal first.id, restored.source_release_id
    assert_equal CohortReleases::Contract::V1_SCHEMA, first.reload.manifest_schema
    assert restored.integrity_valid?, restored.integrity_report.fetch(:errors).inspect
  end

  test "restore rejects stale latest release evidence" do
    owner, cohort, first, = restore_setup
    payload = restore_payload(cohort, first).merge(expected_latest_release_id: first.id)

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: payload },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "restore-stale"), as: :json

    assert_response :conflict
    assert_equal "cohort_release_conflict", response.parsed_body.fetch("code")
  end

  test "restore rejects viewers" do
    owner, cohort, first, = restore_setup
    viewer = persona_user
    cohort.coach_workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: restore_payload(cohort, first) },
      headers: workspace_headers(viewer, cohort.coach_workspace).merge("Idempotency-Key" => "restore-viewer"), as: :json

    assert_response :forbidden
    assert_equal "cohort_release_forbidden", response.parsed_body.fetch("code")
  end

  test "restore rejects read-only cohorts" do
    owner, cohort, first, = restore_setup
    cohort.update!(status: "completed")

    post "#{endpoint(cohort)}/#{first.id}/restore", params: { release: restore_payload(cohort, first) },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "restore-read-only"), as: :json

    assert_response :unprocessable_entity
    assert_equal "cohort_release_read_only", response.parsed_body.fetch("code")
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

  def restore_setup
    owner, cohort, = governed_components
    first = run_seal(cohort, owner, seal_payload(cohort), "restore-source-#{SecureRandom.hex(3)}").release
    publish_changed_experience(cohort, owner)
    second = run_seal(cohort, owner, seal_payload(cohort), "restore-current-#{SecureRandom.hex(3)}").release
    [ owner, cohort, first, second ]
  end

  def restore_payload(cohort, source)
    {
      expected_latest_release_id: cohort.cohort_releases.order(release_number: :desc).pick(:id),
      source_bundle_digest: source.bundle_digest,
      source_persona_version_id: source.coach_persona_version_id,
      source_experience_version_id: source.cohort_experience_version_id,
      source_brand_version_id: source.workspace_brand_version_id
    }
  end

  def seal_payload(cohort)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort.reload, strict: true).call
    {
      expected_assignment_id: candidate.assignment.id,
      expected_bundle_digest: candidate.bundle_digest,
      expected_experience_version_id: candidate.experience_version.id,
      expected_latest_release_id: cohort.cohort_releases.order(release_number: :desc).pick(:id),
      expected_persona_version_id: candidate.persona_version.id,
      expected_brand_version_id: candidate.brand_version&.id,
      expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      expected_tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
  end

  def run_seal(cohort, owner, input, request_key)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal",
      operation_version: CoachOperations::CohortReleaseSeal::VERSION,
      input: input,
      request_key: request_key
    )
  end

  def create_historical_v1_operation!(owner, cohort, request_key:, source_release: nil)
    candidate = source_release ?
      CohortReleases::RestoreCandidateBuilder.new(cohort: cohort, source_release: source_release).call :
      CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    release_number = cohort.cohort_releases.maximum(:release_number).to_i + 1
    previous = cohort.cohort_releases.find_by(release_number: release_number - 1)
    bundle = CohortReleases::Contract.bundle_v1(
      cohort: cohort,
      persona_snapshot: candidate.persona_snapshot,
      experience_snapshot: candidate.experience_snapshot,
      tool_registry_snapshot: candidate.tool_registry_snapshot
    )
    bundle_digest = CohortReleases::Contract.digest(bundle)
    released_at = Time.current
    release_fingerprint = Digest::SHA256.hexdigest("historical-release-#{request_key}")
    event_type = source_release ? "restore" : "release"
    manifest = CohortReleases::Contract.manifest_v1(
      release_number: release_number,
      publication_source: "user",
      event_type: event_type,
      released_by_user_id: owner.id,
      actor_role_snapshot: "owner",
      source_release_id: source_release&.id,
      request_key: request_key,
      request_fingerprint: release_fingerprint,
      released_at: released_at,
      bundle_digest: bundle_digest
    )
    attributes = {
      cohort_id: cohort.id,
      coach_workspace_id: cohort.coach_workspace_id,
      release_number: release_number,
      publication_source: "user",
      event_type: event_type,
      released_by_user_id: owner.id,
      actor_role_snapshot: "owner",
      source_release_id: source_release&.id,
      persona_mode: candidate.persona_snapshot.fetch("mode"),
      coach_persona_id: candidate.persona&.id,
      coach_persona_version_id: candidate.persona_version&.id,
      persona_snapshot: candidate.persona_snapshot,
      persona_snapshot_digest: CohortReleases::Contract.digest(candidate.persona_snapshot),
      experience_mode: candidate.experience_snapshot.fetch("mode"),
      cohort_experience_configuration_id: candidate.experience_configuration.id,
      cohort_experience_version_id: candidate.experience_version&.id,
      experience_snapshot: candidate.experience_snapshot,
      experience_snapshot_digest: CohortReleases::Contract.digest(candidate.experience_snapshot),
      tool_registry_version: CohortReleases::Contract::TOOL_REGISTRY_VERSION,
      tool_registry_snapshot: candidate.tool_registry_snapshot,
      tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      manifest_schema: CohortReleases::Contract::V1_SCHEMA,
      bundle: bundle,
      bundle_digest: bundle_digest,
      manifest: manifest,
      manifest_digest: CohortReleases::Contract.digest(manifest),
      request_key: request_key,
      request_fingerprint: release_fingerprint,
      released_at: released_at,
      created_at: released_at,
      updated_at: released_at
    }
    CohortRelease.insert!(attributes)
    release = cohort.cohort_releases.find_by!(request_key: request_key)
    normalized_input = if source_release
      {
        "expected_latest_release_id" => previous.id,
        "source_bundle_digest" => source_release.bundle_digest,
        "source_experience_version_id" => source_release.cohort_experience_version_id,
        "source_persona_version_id" => source_release.coach_persona_version_id,
        "source_release_id" => source_release.id
      }
    else
      {
        "expected_assignment_id" => candidate.assignment.id,
        "expected_bundle_digest" => bundle_digest,
        "expected_experience_version_id" => candidate.experience_version.id,
        "expected_latest_release_id" => previous&.id,
        "expected_persona_version_id" => candidate.persona_version.id,
        "expected_tool_registry_digest" => CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
        "expected_tool_registry_version" => CohortReleases::Contract::TOOL_REGISTRY_VERSION
      }
    end
    before = operation_state(cohort, previous, release_count: release_number - 1)
    predicted = before.merge(
      "release_count" => release_number,
      "latest_release_id" => nil,
      "latest_release_id_pending" => true,
      "latest_release_number" => release_number,
      "latest_bundle_digest" => bundle_digest
    )
    after = operation_state(cohort, release, release_count: release_number)
    operation_key = source_release ? CoachOperations::CohortReleaseRestore::KEY : CoachOperations::CohortReleaseSeal::KEY
    invocation = CoachOperations::Contract.invocation_fingerprint(
      cohort_id: cohort.id,
      coach_workspace_id: cohort.coach_workspace_id,
      actor_user_id: owner.id,
      actor_role_snapshot: "owner",
      operation_key: operation_key,
      operation_version: 1,
      normalized_input: normalized_input
    )
    execution = cohort.coach_operation_executions.create!(
      coach_workspace: cohort.coach_workspace,
      actor_user: owner,
      actor_role_snapshot: "owner",
      operation_key: operation_key,
      operation_version: 1,
      source: "api",
      request_key: request_key,
      normalized_input: normalized_input,
      normalized_input_digest: CoachOperations::Contract.digest(normalized_input),
      invocation_fingerprint: invocation,
      request_fingerprint: CoachOperations::Contract.request_fingerprint(
        request_key: request_key,
        invocation_fingerprint: invocation
      ),
      before_snapshot: before,
      before_snapshot_digest: CoachOperations::Contract.digest(before),
      predicted_after_snapshot: predicted,
      predicted_after_snapshot_digest: CoachOperations::Contract.digest(predicted),
      after_snapshot: after,
      after_snapshot_digest: CoachOperations::Contract.digest(after),
      cohort_release: release,
      completed_at: released_at
    )
    [ release, execution ]
  end

  def operation_state(cohort, release, release_count:)
    {
      "schema" => "cohort_release_state_v1",
      "cohort_id" => cohort.id,
      "coach_workspace_id" => cohort.coach_workspace_id,
      "release_count" => release_count,
      "latest_release_id" => release&.id,
      "latest_release_number" => release&.release_number,
      "latest_bundle_digest" => release&.bundle_digest,
      "participant_runtime_changed" => false
    }
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
