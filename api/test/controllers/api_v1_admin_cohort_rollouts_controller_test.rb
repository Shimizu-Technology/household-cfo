# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCohortRolloutsControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "studio is privacy safe and viewer access is read only" do
    owner, cohort, participants, = rollout_components
    participants.first.update!(first_name: nil, last_name: nil)
    viewer = persona_user
    cohort.coach_workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    get endpoint(cohort), headers: workspace_headers(owner, cohort.coach_workspace)
    assert_response :success
    owner_studio = response.parsed_body.fetch("cohort_rollout_studio")
    assert owner_studio.dig("permissions", "manage")
    assert_equal false, owner_studio.dig("runtime_truth", "participant_runtime_changed")
    assert_equal participants.map(&:id).sort,
      owner_studio.dig("current_roster", "participants").pluck("user_id").sort
    refute_includes response.body, "@example.com"
    refute_includes response.body, owner.email.split("@").first
    refute_includes response.body, participants.first.email.split("@").first
    assert_includes owner_studio.dig("current_roster", "participants").pluck("full_name"),
      "Participant #{participants.first.id}"

    get endpoint(cohort), headers: workspace_headers(viewer, cohort.coach_workspace)
    assert_response :success
    assert_equal false, response.parsed_body.dig("cohort_rollout_studio", "permissions", "manage")
  end

  test "plan requires idempotency and returns 201 then a stable 200 replay" do
    owner, cohort, participants, release = rollout_components
    payload = plan_payload(cohort, release, participants)
    headers = workspace_headers(owner, cohort.coach_workspace)

    post endpoint(cohort), params: { rollout: payload }, headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "cohort_rollout_invalid", response.parsed_body.fetch("code")

    request_headers = headers.merge("Idempotency-Key" => "rollout-plan-1")
    post endpoint(cohort), params: { rollout: payload }, headers: request_headers, as: :json
    assert_response :created
    created = response.parsed_body
    rollout_id = created.dig("rollout", "id")
    assert_equal false, created.fetch("replayed")
    assert_equal "planned", created.dig("rollout", "status")
    assert_equal "planned", created.dig("transition", "event_type")
    assert_equal false, created.dig("transition", "participant_runtime_changed")
    assert_equal "cohort.rollout.plan", created.dig("operation_execution", "operation_key")
    assert_equal created.dig("transition", "id"),
      created.dig("operation_execution", "cohort_rollout_transition_id")

    get endpoint(cohort), headers: headers
    assert_response :success
    index_payload = response.parsed_body.fetch("cohort_rollout_studio")
    assert index_payload.dig("open_rollout", "waves").present?
    assert_nil index_payload.dig("rollouts", 0, "waves")

    post endpoint(cohort), params: { rollout: payload }, headers: request_headers, as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("replayed")
    assert_equal rollout_id, response.parsed_body.dig("rollout", "id")
    assert_equal 1, cohort.reload.cohort_rollouts.count
    assert_equal 1, cohort.coach_operation_executions.where(operation_key: "cohort.rollout.plan").count

    post endpoint(cohort), params: { rollout: payload },
      headers: headers.merge("Idempotency-Key" => "second-open-plan"), as: :json
    assert_response :conflict
    assert_equal "cohort_rollout_conflict", response.parsed_body.fetch("code")

    changed = payload.deep_dup
    changed[:waves][0][:name] = "Changed plan"
    post endpoint(cohort), params: { rollout: changed }, headers: request_headers, as: :json
    assert_response :conflict
    assert_equal "cohort_rollout_conflict", response.parsed_body.fetch("code")

    rollout = cohort.cohort_rollouts.find(rollout_id)
    post "#{endpoint(cohort)}/#{rollout.id}/cancel", params: { rollout: transition_payload(rollout) },
      headers: headers.merge("Idempotency-Key" => "rollout-cancel-1"), as: :json
    assert_response :created
    assert_equal "cancelled", response.parsed_body.dig("transition", "event_type")
    assert_equal "cancelled", rollout.reload.status

    get "#{endpoint(cohort)}/#{rollout.id}", headers: headers
    assert_response :success
    assert_equal 2, response.parsed_body.dig("rollout", "waves").length
    assert_equal "cancelled", response.parsed_body.dig("rollout", "status")
  end

  test "advance rejects unready and stale evidence before recording a ready wave" do
    owner, cohort, participants, release = rollout_components(second_status: "pending")
    rollout = plan_through_api(owner, cohort, plan_payload(cohort, release, participants.reverse))
    headers = workspace_headers(owner, cohort.coach_workspace)
    stale_payload = transition_payload(rollout).merge(
      readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout)
    )

    post "#{endpoint(cohort)}/#{rollout.id}/advance", params: { rollout: stale_payload },
      headers: headers.merge("Idempotency-Key" => "advance-blocked"), as: :json
    assert_response :unprocessable_entity
    assert_equal "cohort_rollout_incomplete", response.parsed_body.fetch("code")
    assert_includes response.parsed_body.fetch("errors").join(" "), "must be ready"
    assert_equal "planned", rollout.reload.status

    participants.second.update!(invitation_status: "accepted", clerk_id: "clerk_#{SecureRandom.hex(8)}")
    post "#{endpoint(cohort)}/#{rollout.id}/advance", params: { rollout: stale_payload },
      headers: headers.merge("Idempotency-Key" => "advance-stale"), as: :json
    assert_response :conflict
    assert_equal "cohort_rollout_conflict", response.parsed_body.fetch("code")

    ready_payload = transition_payload(rollout.reload).merge(
      readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout)
    )
    request_headers = headers.merge("Idempotency-Key" => "advance-ready")
    post "#{endpoint(cohort)}/#{rollout.id}/advance", params: { rollout: ready_payload },
      headers: request_headers, as: :json
    assert_response :created
    assert_equal "activated", response.parsed_body.dig("transition", "event_type")
    assert_equal "active", response.parsed_body.dig("rollout", "status")
    assert_equal false, response.parsed_body.dig("cohort_rollout_studio", "runtime_truth", "changes_participant_runtime")

    post "#{endpoint(cohort)}/#{rollout.id}/advance", params: { rollout: ready_payload },
      headers: request_headers, as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("replayed")
  end

  test "viewer mutations are forbidden and other workspaces cannot discover a cohort" do
    owner, cohort, participants, release = rollout_components
    viewer = persona_user
    cohort.coach_workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")
    outsider = persona_user
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(outsider)
    payload = plan_payload(cohort, release, participants)

    post endpoint(cohort), params: { rollout: payload },
      headers: workspace_headers(viewer, cohort.coach_workspace).merge("Idempotency-Key" => "viewer-plan"), as: :json
    assert_response :forbidden
    assert_equal "cohort_rollout_forbidden", response.parsed_body.fetch("code")

    get endpoint(cohort), headers: workspace_headers(outsider, other_workspace)
    assert_response :not_found
    post endpoint(cohort), params: { rollout: payload },
      headers: workspace_headers(outsider, other_workspace).merge("Idempotency-Key" => "cross-plan"), as: :json
    assert_response :not_found

    rollout = plan_through_api(owner, cohort, payload)
    get "#{endpoint(cohort)}/#{rollout.id}", headers: workspace_headers(viewer, cohort.coach_workspace)
    assert_response :success
    assert_equal false, response.parsed_body.dig("rollout", "permissions", "advance")
    assert response.parsed_body.dig("rollout", "waves").present?

    get "#{endpoint(cohort)}/#{rollout.id}", headers: workspace_headers(outsider, other_workspace)
    assert_response :not_found
  end

  test "pause resume and rollback endpoints preserve participant runtime" do
    owner, cohort, participants, earlier_release = rollout_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    target_release = CohortReleases::Sealer.new(
      cohort: cohort,
      actor: nil,
      publication_source: "system"
    ).call!(request_key: "rollout-api-target", expected_bundle_digest: candidate.bundle_digest)
    rollout = plan_through_api(owner, cohort, plan_payload(cohort, target_release, participants))
    headers = workspace_headers(owner, cohort.coach_workspace)

    advance = transition_payload(rollout).merge(
      readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout)
    )
    post "#{endpoint(cohort)}/#{rollout.id}/advance", params: { rollout: advance },
      headers: headers.merge("Idempotency-Key" => "lifecycle-advance"), as: :json
    assert_response :created

    post "#{endpoint(cohort)}/#{rollout.id}/pause", params: { rollout: transition_payload(rollout) },
      headers: headers.merge("Idempotency-Key" => "lifecycle-pause"), as: :json
    assert_response :created
    assert_equal "paused", response.parsed_body.dig("rollout", "status")

    post "#{endpoint(cohort)}/#{rollout.id}/resume", params: { rollout: transition_payload(rollout) },
      headers: headers.merge("Idempotency-Key" => "lifecycle-resume"), as: :json
    assert_response :created
    assert_equal "active", response.parsed_body.dig("rollout", "status")

    rollback = transition_payload(rollout).merge(rollback_release_id: earlier_release.id)
    post "#{endpoint(cohort)}/#{rollout.id}/rollback", params: { rollout: rollback },
      headers: headers.merge("Idempotency-Key" => "lifecycle-rollback"), as: :json
    assert_response :created
    assert_equal "rolled_back", response.parsed_body.dig("transition", "event_type")
    assert_equal earlier_release.id, response.parsed_body.dig("rollout", "rollback_release", "id")
    assert_equal false, response.parsed_body.dig("transition", "participant_runtime_changed")
    assert_equal false, response.parsed_body.dig("rollout", "participant_runtime_changed")

    get "#{endpoint(cohort)}/#{rollout.id}", headers: headers
    assert_response :success
    activation = response.parsed_body.dig("rollout", "transitions").find do |transition|
      transition.fetch("event_type") == "activated"
    end
    assert_match(/\A[0-9a-f]{64}\z/, activation.fetch("readiness_digest"))
  end

  test "closed cohorts reject new rollout plans with a stable read only code" do
    owner, cohort, participants, release = rollout_components
    cohort.update!(status: "completed")

    post endpoint(cohort), params: { rollout: plan_payload(cohort, release, participants) },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "closed-plan"), as: :json

    assert_response :unprocessable_entity
    assert_equal "cohort_rollout_read_only", response.parsed_body.fetch("code")
    assert_empty cohort.reload.cohort_rollouts
  end

  private

  def rollout_components(second_status: "accepted")
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Rollout API #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    first = participant
    second = participant(invitation_status: second_status)
    cohort.cohort_memberships.create!(user: first, role: "participant")
    cohort.cohort_memberships.create!(user: second, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    [ owner, cohort, [ first, second ], cohort.cohort_releases.sole ]
  end

  def participant(invitation_status: "accepted")
    pending = invitation_status == "pending"
    User.create!(
      clerk_id: pending ? "pending_#{SecureRandom.hex(8)}" : "clerk_#{SecureRandom.hex(8)}",
      email: "#{SecureRandom.hex(8)}@example.com",
      role: "participant",
      invitation_status: invitation_status,
      first_name: "Test",
      last_name: "Household"
    )
  end

  def plan_payload(cohort, release, participants)
    {
      target_release_id: release.id,
      expected_latest_release_id: release.id,
      expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
      waves: participants.each_with_index.map do |user, index|
        { name: "Wave #{index + 1}", user_ids: [ user.id ] }
      end
    }
  end

  def plan_through_api(owner, cohort, payload)
    post endpoint(cohort), params: { rollout: payload },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :created
    cohort.cohort_rollouts.find(response.parsed_body.dig("rollout", "id"))
  end

  def transition_payload(rollout)
    rollout.reload
    {
      expected_status: rollout.status,
      expected_current_wave_position: rollout.current_wave_position,
      expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id)
    }
  end

  def endpoint(cohort)
    "/api/v1/admin/cohorts/#{cohort.id}/rollouts"
  end

  def workspace_headers(user, workspace)
    {
      "Authorization" => "Bearer test_token_#{user.id}",
      "X-Coach-Workspace-Id" => workspace.id.to_s
    }
  end
end
