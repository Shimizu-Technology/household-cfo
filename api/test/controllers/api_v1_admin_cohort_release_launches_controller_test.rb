# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCohortReleaseLaunchesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "owner launches once with immutable actor evidence and participant runtime switches" do
    owner, cohort, release = launch_setup
    participant = persona_user(role: "participant")
    membership = participant.cohort_memberships.create!(cohort: cohort, role: "participant")
    before = review(owner, cohort)
    assert before.fetch("can_launch")
    assert_equal 1, before.dig("cohort", "participant_count")
    assert_nil cohort.reload.active_cohort_release_id
    refute_includes response.body, participant.email
    refute_includes response.body, "draft_config"
    input = { release_id: release.id, preview_digest: before.fetch("preview_digest") }
    headers = workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "first-launch")

    post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
    assert_response :created
    assert_equal release.id, cohort.reload.active_cohort_release_id
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    event = cohort.cohort_release_activation_events.sole
    assert_equal "initial_launch", event.event_type
    assert_equal owner.id, event.actor_user_id
    assert_equal "owner", event.actor_role_snapshot
    assert_nil event.from_cohort_release_id
    assert_equal release.id, Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call.release_id
    assert_equal "replayed", CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!.status
    assert_no_difference -> { cohort.cohort_release_activation_events.count } do
      post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
    end
    assert_response :success
    assert response.parsed_body.fetch("replayed")
    refute event.update(occurred_at: 1.day.ago)
    assert_raises(ActiveRecord::StatementInvalid) { event.update_columns(occurred_at: 1.day.ago) }
  end

  test "reviewer can launch but editor and viewer cannot even replay after demotion" do
    _owner, cohort, release = launch_setup
    reviewer = persona_user
    cohort.coach_workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    input = { release_id: release.id, preview_digest: review(reviewer, cohort).fetch("preview_digest") }
    headers = workspace_headers(reviewer, cohort.coach_workspace).merge("Idempotency-Key" => "reviewer-launch")
    post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
    assert_response :created
    assert_equal "reviewer", cohort.cohort_release_activation_events.sole.actor_role_snapshot
    %w[editor viewer].each do |role|
      cohort.coach_workspace.membership_for(reviewer).update!(role: role)
      post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
      assert_response :forbidden
    end
    assert_equal 1, cohort.cohort_release_activation_events.count
  end

  test "stale roster and mismatched retries cannot mutate launch state" do
    owner, cohort, release = launch_setup
    digest = review(owner, cohort).fetch("preview_digest")
    persona_user(role: "participant").cohort_memberships.create!(cohort: cohort, role: "participant")
    headers = workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "stale-launch")
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: digest } }, headers: headers, as: :json
    assert_response :conflict
    assert_nil cohort.reload.active_cohort_release_id
    input = { release_id: release.id, preview_digest: review(owner, cohort).fetch("preview_digest") }
    post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
    assert_response :created
    post endpoint(cohort), params: { launch: input.merge(preview_digest: "f" * 64) }, headers: headers, as: :json
    assert_response :conflict
    post endpoint(cohort), params: { launch: input }, headers: headers.merge("Idempotency-Key" => "second-launch"), as: :json
    assert_response :conflict
    assert_equal 1, cohort.cohort_release_activation_events.count
  end

  test "changed published settings must be resealed before launch" do
    owner, cohort, release = launch_setup
    before = review(owner, cohort)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: CohortExperience::Schema::LEGACY_CONFIG, last_edited_by_user: owner)
    publish_tools(configuration, owner)
    headers = workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "changed-settings")
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: before.fetch("preview_digest") } }, headers: headers, as: :json
    assert_response :conflict
    latest = review(owner, cohort)
    refute latest.fetch("can_launch")
    assert_includes latest.fetch("blockers"), "The published settings changed. Seal their new release before launching."
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: latest.fetch("preview_digest") } }, headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_nil cohort.reload.active_cohort_release_id
  end

  test "read only and unsealed cohorts cannot launch and foreign workspace stays hidden" do
    owner, cohort, release = launch_setup
    cohort.update!(status: "completed")
    before = review(owner, cohort)
    refute before.fetch("can_launch")
    assert_includes before.fetch("blockers"), "Completed and archived cohorts are read-only."
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: before.fetch("preview_digest") } },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "closed-launch"), as: :json
    assert_response :unprocessable_entity
    outsider = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(outsider)
    get endpoint(cohort), headers: workspace_headers(outsider, workspace)
    assert_response :not_found
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: before.fetch("preview_digest") } },
      headers: workspace_headers(outsider, workspace).merge("Idempotency-Key" => "outside-launch"), as: :json
    assert_response :not_found
    unsealed = Cohort.create!(name: "No sealed release", status: "draft", created_by_user: owner, coach_workspace: cohort.coach_workspace)
    state = review(owner, unsealed)
    refute state.fetch("can_launch")
    assert_includes state.fetch("blockers"), "Seal a release before launching this cohort."
    assert_nil cohort.reload.active_cohort_release_id
  end

  test "an open legacy rollout blocks first launch" do
    owner, cohort, = launch_setup
    participant = persona_user(role: "participant")
    participant.cohort_memberships.create!(cohort: cohort, role: "participant")
    release = cohort.cohort_releases.sole
    CohortRollouts::StateMachine.new(cohort: cohort, actor: owner, actor_role_snapshot: "owner").plan!(
      target_release_id: release.id, expected_latest_release_id: release.id,
      expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
      waves: [ { name: "Legacy wave", user_ids: [ participant.id ] } ]
    )
    before = review(owner, cohort)
    refute before.fetch("can_launch")
    assert_includes before.fetch("blockers"), "Finish or cancel the open rollout before launching this cohort."
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: before.fetch("preview_digest") } },
      headers: workspace_headers(owner, cohort.coach_workspace).merge("Idempotency-Key" => "open-rollout"), as: :json
    assert_response :unprocessable_entity
    assert_nil cohort.reload.active_cohort_release_id
  end

  test "platform administrator can launch in platform mode and a newer sealed release invalidates old review" do
    owner, cohort, release = launch_setup
    admin = persona_user(role: "admin")
    before = review(owner, cohort)
    newer = CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
      request_key: "launch-duplicate-bundle"
    )
    assert_operator newer.release_number, :>, release.release_number
    headers = { "Authorization" => "Bearer test_token_#{admin.id}", "Idempotency-Key" => "admin-initial-launch" }
    post endpoint(cohort), params: { launch: { release_id: release.id, preview_digest: before.fetch("preview_digest") } }, headers: headers, as: :json
    assert_response :conflict
    current = review(owner, cohort)
    post endpoint(cohort), params: { launch: { release_id: newer.id, preview_digest: current.fetch("preview_digest") } }, headers: headers, as: :json
    assert_response :created
    assert_equal "platform_admin", cohort.cohort_release_activation_events.sole.actor_role_snapshot
    assert_equal newer.id, cohort.reload.active_cohort_release_id
  end

  test "locked authorization rejects an actor globally demoted or revoked after preview" do
    [ { role: "participant" }, { invitation_status: "revoked" } ].each do |change|
      owner, cohort, release = launch_setup
      before = review(owner, cohort)
      User.find(owner.id).update!(change)
      assert_raises(CohortReleases::Authorization::NotAuthorized) do
        CohortReleases::InitialLauncher.new(cohort: cohort, actor: owner).call!(
          release_id: release.id, preview_digest: before.fetch("preview_digest"), request_key: "demoted-actor"
        )
      end
      assert_nil cohort.reload.active_cohort_release_id
      assert_empty cohort.cohort_release_activation_events
    end
  end

  test "database rejects an initial launch without actor evidence" do
    _owner, cohort, release = launch_setup
    assert_raises(ActiveRecord::StatementInvalid) do
      CohortReleaseActivationEvent.transaction(requires_new: true) do
        CohortReleaseActivationEvent.insert_all!([ {
          coach_workspace_id: cohort.coach_workspace_id, cohort_id: cohort.id,
          to_cohort_release_id: release.id, event_type: "initial_launch",
          request_key: "forged-actorless-launch", request_fingerprint: "f" * 64,
          occurred_at: Time.current
        } ])
      end
    end
    assert_empty cohort.cohort_release_activation_events
    assert_nil cohort.reload.active_cohort_release_id
  end

  test "database rejects an initial launch with an actor but no role snapshot" do
    owner, cohort, release = launch_setup
    assert_raises(ActiveRecord::StatementInvalid) do
      CohortReleaseActivationEvent.transaction(requires_new: true) do
        CohortReleaseActivationEvent.insert_all!([ {
          coach_workspace_id: cohort.coach_workspace_id, cohort_id: cohort.id,
          to_cohort_release_id: release.id, event_type: "initial_launch",
          actor_user_id: owner.id, actor_role_snapshot: nil,
          request_key: "forged-roleless-launch", request_fingerprint: "f" * 64,
          occurred_at: Time.current
        } ])
        cohort.update!(active_cohort_release_id: release.id)
      end
    end
    assert_empty cohort.cohort_release_activation_events
    assert_nil cohort.reload.active_cohort_release_id
  end

  test "valid fields and explicit idempotency are mandatory" do
    owner, cohort, release = launch_setup
    headers = workspace_headers(owner, cohort.coach_workspace)
    input = { release_id: release.id, preview_digest: review(owner, cohort).fetch("preview_digest") }
    post endpoint(cohort), params: { launch: input }, headers: headers, as: :json
    assert_response :unprocessable_entity
    post endpoint(cohort), params: { launch: { release_id: release.id } },
      headers: headers.merge("Idempotency-Key" => "missing-digest"), as: :json
    assert_response :unprocessable_entity
    assert_nil cohort.reload.active_cohort_release_id
  end

  private

  def launch_setup
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Initial launch #{SecureRandom.hex(4)}", status: "active", created_by_user: owner, coach_workspace: workspace)
    persona = create_persona(creator: owner, name: "Launch assistant #{SecureRandom.hex(4)}", workspace: workspace)
    version = publish_persona(persona, actor: owner)
    CohortPersonaAssignment.create!(cohort: cohort, coach_workspace: workspace, coach_persona: persona,
      coach_persona_version: version, assigned_by_user: owner)
    publish_tools(cohort.cohort_experience_configuration, owner)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort.reload, strict: true).call
    release = CohortReleases::Sealer.new(cohort: cohort, actor: owner).call!(
      request_key: "launch-seal-#{SecureRandom.hex(4)}", expected_bundle_digest: candidate.bundle_digest,
      expected_assignment_id: candidate.assignment.id, expected_persona_version_id: candidate.persona_version.id,
      expected_experience_version_id: candidate.experience_version.id, expected_brand_version_id: candidate.brand_version.id
    )
    [ owner, cohort, release ]
  end

  def publish_tools(configuration, owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: configuration.current_published_version_id)
  end

  def review(user, cohort)
    get endpoint(cohort), headers: workspace_headers(user, cohort.coach_workspace)
    assert_response :success
    response.parsed_body.fetch("launch")
  end

  def endpoint(cohort)
    "/api/v1/admin/cohorts/#{cohort.id}/launch"
  end

  def workspace_headers(user, workspace)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Coach-Workspace-Id" => workspace.id.to_s }
  end
end
