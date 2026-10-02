# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminPersonaReleaseGatesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "workspace API creates typed cases runs approvals readiness and a gate v2 publication" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    persona = create_persona(creator: owner, workspace: workspace)
    headers = workspace_auth_headers(owner, workspace)

    get "/api/v1/admin/personas/#{persona.id}/release_readiness", headers: headers
    assert_response :success
    initial_readiness = response.parsed_body.fetch("readiness")
    refute initial_readiness.fetch("ready")
    assert_equal 4, initial_readiness.fetch("required_evaluation_cases").length
    assert initial_readiness.dig("permissions", "run_evaluation")
    assert initial_readiness.dig("permissions", "review_evaluations")
    assert initial_readiness.dig("permissions", "publish")
    get "/api/v1/admin/personas/#{persona.id}/evaluation_cases", headers: headers
    assert_response :success
    visible_cases = response.parsed_body.fetch("evaluation_cases")
    assert_equal 4, visible_cases.length
    assert visible_cases.all? { |item| item.fetch("required") && item.fetch("kind") == "system" }
    assert visible_cases.all? { |item| item.fetch("id").nil? }

    case_request_id = SecureRandom.uuid
    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: {
        evaluation_case: {
          request_id: case_request_id,
          name: "Complex purchase",
          prompt: "Can I finance a car while paying down debt?",
          assertions: [ { type: "includes", value: "review" }, { type: "not_fallback" } ]
        }
      }, headers: headers, as: :json
    assert_response :created
    assert_equal "custom", response.parsed_body.dig("evaluation_case", "kind")
    custom_case_id = response.parsed_body.dig("evaluation_case", "id")
    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: {
        evaluation_case: {
          request_id: case_request_id,
          name: "Complex purchase",
          prompt: "Can I finance a car while paying down debt?",
          assertions: [ { type: "includes", value: "review" }, { type: "not_fallback" } ]
        }
      }, headers: headers, as: :json
    assert_response :created
    assert_equal custom_case_id, response.parsed_body.dig("evaluation_case", "id")
    assert response.parsed_body.dig("reconciliation", "replayed")
    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: {
        evaluation_case: {
          request_id: case_request_id,
          name: "Changed payload",
          prompt: "A different request",
          assertions: [ { type: "not_fallback" } ]
        }
      }, headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("error"), "different evaluation case"

    run_request_id = SecureRandom.uuid
    with_live_evaluation do
      perform_enqueued_jobs do
        post "/api/v1/admin/personas/#{persona.id}/evaluation_runs",
          params: { evaluation_run: { request_id: run_request_id } }, headers: headers, as: :json
      end
    end
    assert_response :accepted
    run_payload = response.parsed_body.fetch("evaluation_run")
    assert_equal "passed", run_payload.fetch("status")
    assert_equal false, run_payload.fetch("results").any? { |result| result.fetch("fallback_only") }
    assert_equal owner.id, run_payload.dig("requested_by", "id")
    post "/api/v1/admin/personas/#{persona.id}/evaluation_runs",
      params: { evaluation_run: { request_id: run_request_id } }, headers: headers, as: :json
    assert_response :accepted
    assert response.parsed_body.dig("reconciliation", "replayed")
    assert_equal run_payload.fetch("id"), response.parsed_body.dig("evaluation_run", "id")

    post "/api/v1/admin/personas/#{persona.id}/evaluation_runs/#{run_payload.fetch('id')}/approval",
      params: { approval: { decision: "approved", run_digest: run_payload.fetch("run_digest") } },
      headers: headers, as: :json
    assert_response :created
    approval = response.parsed_body.fetch("approval")
    assert_equal true, approval.fetch("self_review")
    behavioral = Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: persona, actor: owner).call!(
      candidate: CoachPersonaEvaluationRun.find(run_payload.fetch("id")).release_candidate,
      preview: {
        status: "ready", source: "live_model", sample_prompt: "Test the exact candidate.",
        sample_reply: "Review the exact candidate facts.", model_identifier: "test-model",
        context_digest: Mia::PersonaPreviewer.context_digest
      }
    )

    get "/api/v1/admin/personas/#{persona.id}/release_readiness", headers: headers
    assert_response :success
    readiness = response.parsed_body.fetch("readiness")
    assert_equal true, readiness.fetch("ready")
    assert_empty readiness.fetch("blockers")

    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    post "/api/v1/admin/personas/#{persona.id}/publish",
      params: {
        publish: {
          draft_revision: persona.draft_revision,
          preview_digest: preview.fetch(:digest),
          expected_published_version_id: nil,
          release_candidate_digest: readiness.dig("candidate", "manifest_digest"),
          evaluation_run_digest: run_payload.fetch("run_digest"),
          evaluation_approval_digest: approval.fetch("approval_digest"),
          behavioral_preview_digest: behavioral.evidence_digest
        }
      }, headers: headers, as: :json
    assert_response :success
    assert_equal "gate_v2", response.parsed_body.dig("published_version", "release_gate_version")
    published = CoachPersonaVersion.find(response.parsed_body.dig("published_version", "id"))
    assert published.release_evidence_valid?

    delete "/api/v1/admin/personas/#{persona.id}/evaluation_cases/#{custom_case_id}", headers: headers
    assert_response :success
    assert_equal false, response.parsed_body.dig("evaluation_case", "active")
    assert_equal true, response.parsed_body.dig("evaluation_case", "retirement_valid")
    refute CoachPersonaEvaluationRun.find(run_payload.fetch("id")).current_suite_pass?
    assert published.reload.release_evidence_valid?, "retirement must not corrupt historical publication evidence"
  end

  test "mutations require a selected workspace and conceal another workspace persona" do
    first_owner = persona_user
    second_owner = persona_user
    platform_admin = persona_user(role: "admin")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    persona = create_persona(creator: first_owner, workspace: first_workspace)

    post "/api/v1/admin/personas/#{persona.id}/evaluation_runs",
      params: { evaluation_run: { request_id: SecureRandom.uuid } }, headers: auth_headers(platform_admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    post "/api/v1/admin/personas/#{persona.id}/evaluation_runs",
      params: { evaluation_run: { request_id: SecureRandom.uuid } },
      headers: workspace_auth_headers(second_owner, second_workspace), as: :json
    assert_response :not_found

    get "/api/v1/admin/personas/#{persona.id}/release_readiness",
      headers: workspace_auth_headers(second_owner, second_workspace)
    assert_response :not_found

    custom = persona.evaluation_cases.new(
      coach_workspace: first_workspace, created_by_user: first_owner, name: "Private case",
      case_kind: "custom", prompt: "Test", assertions: [ { "type" => "not_fallback" } ],
      required: false, active: true, request_key: "private-#{SecureRandom.uuid}", request_fingerprint: "e" * 64
    )
    custom.case_digest = CoachPersonaEvaluationCase.digest_for(custom)
    custom.save!
    delete "/api/v1/admin/personas/#{persona.id}/evaluation_cases/#{custom.id}", headers: auth_headers(platform_admin)
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")
    assert custom.reload.active?
  end

  test "case API rejects unbounded and untyped assertions" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    persona = create_persona(creator: owner, workspace: workspace)

    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: {
        evaluation_case: {
          request_id: SecureRandom.uuid,
          name: "Unsafe assertion",
          prompt: "Test",
          assertions: [ { type: "regex", value: ".*" } ]
        }
      }, headers: workspace_auth_headers(owner, workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "persona_evaluation_case_invalid", response.parsed_body.fetch("code")
    assert_includes response.parsed_body.fetch("error"), "unsupported assertion type"
  end

  test "new API personas cannot bypass gate v2 by omitting release evidence" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    headers = workspace_auth_headers(owner, workspace)
    post "/api/v1/admin/personas",
      params: { persona: { name: "Release guarded assistant" } }, headers: headers, as: :json
    assert_response :created
    persona = CoachPersona.find(response.parsed_body.dig("persona", "id"))
    assert_equal "gate_v2", persona.release_gate_version
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)

    post "/api/v1/admin/personas/#{persona.id}/publish",
      params: {
        publish: {
          draft_revision: persona.draft_revision,
          preview_digest: preview.fetch(:digest),
          expected_published_version_id: nil
        }
      }, headers: headers, as: :json
    assert_response :conflict
    assert_equal "persona_publish_conflict", response.parsed_body.fetch("code")
    assert_includes response.parsed_body.fetch("error"), "Complete release evidence"
    assert_nil persona.reload.current_published_version_id
  end

  test "custom case capacity can be recovered by retiring an old case" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    persona = create_persona(creator: owner, workspace: workspace)
    headers = workspace_auth_headers(owner, workspace)
    limit = Mia::PersonaRelease::Runner::MAX_CASES - Mia::PersonaRelease::SystemCases::DEFINITIONS.length
    cases = limit.times.map do |index|
      record = persona.evaluation_cases.new(
        coach_workspace: workspace,
        created_by_user: owner,
        name: "Custom case #{index + 1}",
        case_kind: "custom",
        prompt: "Review scenario #{index + 1}.",
        assertions: [ { "type" => "not_fallback" } ],
        required: false,
        active: true,
        request_key: "capacity-#{SecureRandom.uuid}",
        request_fingerprint: "f" * 64
      )
      record.case_digest = CoachPersonaEvaluationCase.digest_for(record)
      record.save!
      record
    end

    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: { evaluation_case: { request_id: SecureRandom.uuid, name: "One too many", prompt: "Test", assertions: [ { type: "not_fallback" } ] } },
      headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("error"), "Retire an existing custom evaluation case"

    delete "/api/v1/admin/personas/#{persona.id}/evaluation_cases/#{cases.first.id}", headers: headers
    assert_response :success
    retired = cases.first.reload
    refute retired.active?
    assert retired.retirement_digest.present?
    assert retired.retirement_integrity_valid?
    refute retired.update(active: true)

    original_retired_at = retired.retired_at
    retired.update_column(:retired_at, original_retired_at + 1.second)
    refute retired.reload.retirement_integrity_valid?
    retired.update_columns(retired_at: original_retired_at)
    assert retired.reload.retirement_integrity_valid?

    post "/api/v1/admin/personas/#{persona.id}/evaluation_cases",
      params: { evaluation_case: { request_id: SecureRandom.uuid, name: "Corrected case", prompt: "Test", assertions: [ { type: "not_fallback" } ] } },
      headers: headers, as: :json
    assert_response :created
    corrected_id = response.parsed_body.dig("evaluation_case", "id")

    persona.archive!
    delete "/api/v1/admin/personas/#{persona.id}/evaluation_cases/#{corrected_id}", headers: headers
    assert_response :unprocessable_entity
    assert_equal "Archived personas are read-only", response.parsed_body.fetch("error")
  end

  private

  def with_live_evaluation
    original = Mia::PersonaRelease::LiveBehavioralAdapter.instance_method(:call)
    Mia::PersonaRelease::LiveBehavioralAdapter.define_method(:call) do |evaluation_case:, persona:, candidate:|
      Mia::PersonaRelease::BehavioralAdapter::Response.new(
        output: "Review the exact candidate facts before choosing the next step.",
        metadata: { "source" => "live_model", "candidate_digest" => candidate.manifest_digest },
        fallback_only: false
      )
    end
    yield
  ensure
    Mia::PersonaRelease::LiveBehavioralAdapter.define_method(:call, original) if original
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_auth_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
