# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminPersonaSetupControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  setup do
    @owner = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @owner).call
    @persona = create_persona(creator: @owner, workspace: @workspace, name: "Chat setup assistant")
    @headers = workspace_auth_headers(@owner, @workspace)
  end

  test "setup requires an explicitly selected workspace for platform admins" do
    admin = persona_user(role: "admin")

    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: auth_headers(admin), as: :json

    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")
  end

  test "sessions are private to each editor and isolated by workspace and role" do
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: @headers, as: :json
    assert_response :created
    owner_session_id = response.parsed_body.dig("session", "id")

    editor = persona_user
    @workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: workspace_auth_headers(editor, @workspace), as: :json
    assert_response :created
    editor_session_id = response.parsed_body.dig("session", "id")
    refute_equal owner_session_id, editor_session_id

    get "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{editor_session_id}", headers: @headers
    assert_response :not_found

    viewer = persona_user
    @workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: workspace_auth_headers(viewer, @workspace), as: :json
    assert_response :not_found

    reviewer = persona_user
    @workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: workspace_auth_headers(reviewer, @workspace), as: :json
    assert_response :not_found

    outside_owner = persona_user
    outside_workspace = CoachWorkspaces::Resolver.new(user: outside_owner).call
    get "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{owner_session_id}", headers: workspace_auth_headers(outside_owner, outside_workspace)
    assert_response :not_found
  end

  test "create resumes one active session and abandon prevents rebase" do
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: @headers, as: :json
    first_id = response.parsed_body.dig("session", "id")
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: @headers, as: :json
    assert_equal first_id, response.parsed_body.dig("session", "id")
    assert_equal 1, CoachPersonaSetupSession.active.where(coach_persona: @persona, created_by_user: @owner).count

    delete "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{first_id}", headers: @headers
    assert_response :success
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{first_id}/rebase", headers: @headers, as: :json
    assert_response :conflict
    assert_equal "persona_setup_inactive", response.parsed_body.fetch("code")
  end

  test "rebase never revives inactive sessions when a replacement session exists" do
    %w[abandoned completed].each do |status|
      old_session = CoachPersonaSetupSession.create!(
        coach_persona: @persona,
        coach_workspace: @workspace,
        created_by_user: @owner,
        status:,
        base_draft_revision: @persona.draft_revision,
        base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config),
        last_activity_at: Time.current
      )
      replacement = CoachPersonaSetupSession.create!(
        coach_persona: @persona,
        coach_workspace: @workspace,
        created_by_user: @owner,
        base_draft_revision: @persona.draft_revision,
        base_config_digest: Mia::PersonaSchema.digest(@persona.draft_config),
        last_activity_at: Time.current
      )

      post "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{old_session.id}/rebase", headers: @headers, as: :json

      assert_response :conflict
      assert_equal "persona_setup_inactive", response.parsed_body.fetch("code")
      assert_equal status, old_session.reload.status
      assert_equal "active", replacement.reload.status
      replacement.update!(status: "abandoned")
    end
  end

  test "turn proposal review apply and exact replay update only the draft" do
    session_id = create_setup_session
    resolver = fixed_resolver(
      "I prepared one name change for review.",
      [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]
    )
    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "turn-controller-123"), as: :json
    end
    assert_response :created
    proposal = response.parsed_body.dig("session", "proposal")
    assert_equal "Identity", proposal.dig("grouped_changes", 0, "group")
    assert_equal "coach_quote", proposal.dig("grouped_changes", 0, "changes", 0, "source_basis")
    assert_equal "Lina", proposal.dig("after_state", "draft_config", "identity", "assistant_name")
    assert_equal 1, @persona.reload.draft_revision
    assert_empty @persona.versions
    assert_empty @persona.cohort_persona_assignments

    apply_path = "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{session_id}/proposals/#{proposal.fetch('id')}/apply"
    2.times do
      post apply_path, headers: @headers.merge("Idempotency-Key" => "apply-controller-123"), as: :json
      assert_response :success
    end
    assert_equal "Lina", @persona.reload.name
    assert_equal 2, @persona.draft_revision
    assert_nil @persona.preview_digest
    assert_empty @persona.versions
    assert_empty @persona.cohort_persona_assignments
  end

  test "conflicting turn idempotency is rejected without a second provider call" do
    session_id = create_setup_session
    resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "same-turn-key"), as: :json
      assert_response :created
      post turn_path(session_id), params: { turn: { message: "Call the assistant Ava." } },
        headers: @headers.merge("Idempotency-Key" => "same-turn-key"), as: :json
    end

    assert_response :conflict
    assert_equal "persona_setup_idempotency_conflict", response.parsed_body.fetch("code")
    assert_equal 1, CoachPersonaSetupTurn.where(coach_persona_setup_session_id: session_id).count
  end

  test "missing turn input returns the stable invalid contract without reserving work" do
    session_id = create_setup_session

    post turn_path(session_id), params: { turn: {} },
      headers: @headers.merge("Idempotency-Key" => "missing-turn-input"), as: :json

    assert_response :unprocessable_entity
    assert_equal "persona_setup_invalid", response.parsed_body.fetch("code")
    assert_empty CoachPersonaSetupTurn.where(coach_persona_setup_session_id: session_id)
  end

  test "provider failure records a safe failed turn and no proposal" do
    session_id = create_setup_session
    resolver = Object.new
    resolver.define_singleton_method(:call) do |**|
      raise Mia::PersonaSetup::ProposalResolver::Error.new("Persona setup timed out. Try again.", code: "persona_setup_unavailable")
    end

    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Help with the voice." } },
        headers: @headers.merge("Idempotency-Key" => "failed-turn-key"), as: :json
    end

    assert_response :service_unavailable
    assert_equal "failed", response.parsed_body.dig("session", "turns", 0, "status")
    assert_nil response.parsed_body.dig("session", "proposal")
    assert_equal "persona_setup_unavailable", CoachPersonaSetupTurn.last.error_code
    assert_empty CoachPersonaSetupProposal.where(coach_persona_setup_session_id: session_id)
  end

  test "role removal during provider work invalidates the reserved turn" do
    session_id = create_setup_session
    membership = @workspace.coach_workspace_memberships.find_by!(user: @owner)
    resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]) do
      membership.update!(role: "viewer")
    end

    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "demoted-turn-key"), as: :json
    end

    assert_response :not_found
    assert_equal "stale", CoachPersonaSetupTurn.last.status
    assert_empty CoachPersonaSetupProposal.where(coach_persona_setup_session_id: session_id)
  end

  test "membership removal during provider work leaves no zombie turn after access is restored" do
    session_id = create_setup_session
    membership = @workspace.coach_workspace_memberships.find_by!(user: @owner)
    resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ]) do
      membership.destroy!
    end

    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "removed-turn-key"), as: :json
    end
    assert_response :not_found
    assert_equal "stale", CoachPersonaSetupTurn.last.status

    @workspace.coach_workspace_memberships.create!(user: @owner, role: "editor")
    retry_resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    with_controller_resolver(retry_resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "restored-turn-key"), as: :json
    end
    assert_response :created
    assert_equal "ready", response.parsed_body.dig("session", "turns", 1, "status")
  end

  test "rebase stales an older proposal after manual draft change" do
    session_id = create_setup_session
    resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "stale-turn-key"), as: :json
    end
    proposal_id = response.parsed_body.dig("session", "proposal", "id")
    changed = @persona.draft_config.deep_merge("voice" => { "energy" => "Warm and encouraging." })
    patch "/api/v1/admin/personas/#{@persona.id}", params: {
      persona: { draft_revision: @persona.draft_revision, draft_config: changed }
    }, headers: @headers, as: :json
    assert_response :success
    assert_equal "stale", CoachPersonaSetupProposal.find(proposal_id).status

    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{session_id}/rebase", headers: @headers, as: :json
    assert_response :success
    assert_equal false, response.parsed_body.dig("session", "stale")
    assert_nil response.parsed_body.dig("session", "proposal")
  end

  test "archived persona rejects proposal apply without changing its state" do
    session_id = create_setup_session
    resolver = fixed_resolver("Review it.", [ operation("identity.assistant_name", "Lina", evidence: "Lina") ])
    with_controller_resolver(resolver) do
      post turn_path(session_id), params: { turn: { message: "Call the assistant Lina." } },
        headers: @headers.merge("Idempotency-Key" => "archive-turn-key"), as: :json
    end
    proposal_id = response.parsed_body.dig("session", "proposal", "id")
    @persona.archive!

    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{session_id}/proposals/#{proposal_id}/apply",
      headers: @headers.merge("Idempotency-Key" => "archive-apply-key"), as: :json
    assert_response :conflict
    assert_equal "persona_archived", response.parsed_body.fetch("code")
    assert_equal "pending", CoachPersonaSetupProposal.find(proposal_id).status
  end

  private

  def create_setup_session
    post "/api/v1/admin/personas/#{@persona.id}/setup_sessions", headers: @headers, as: :json
    assert_response :created
    response.parsed_body.dig("session", "id")
  end

  def turn_path(session_id)
    "/api/v1/admin/personas/#{@persona.id}/setup_sessions/#{session_id}/turns"
  end

  def operation(path, value, source: "coach_quote", evidence:)
    { "op" => "set", "path" => path, "value" => value, "source_basis" => source, "evidence_quote" => evidence }
  end

  def fixed_resolver(message, operations, &before_return)
    Object.new.tap do |resolver|
      resolver.define_singleton_method(:call) do |**|
        before_return&.call
        Mia::PersonaSetup::ProposalResolver::Result.new(
          assistant_message: message,
          operations:,
          metadata: {
            "provider" => "openrouter", "model" => "exact/model",
            "prompt_version" => Mia::PersonaSetup::ProposalBuilder::PROMPT_VERSION,
            "schema_version" => Mia::PersonaSetup::ProposalBuilder::SCHEMA_VERSION,
            "usage" => { "total_tokens" => 12 }
          }
        )
      end
    end
  end

  def with_controller_resolver(resolver)
    controller = Api::V1::Admin::PersonaSetupTurnsController
    original = controller.instance_method(:proposal_resolver)
    controller.define_method(:proposal_resolver) { resolver }
    controller.send(:private, :proposal_resolver)
    yield
  ensure
    controller.define_method(:proposal_resolver, original)
    controller.send(:private, :proposal_resolver)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_auth_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
