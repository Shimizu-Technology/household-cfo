# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1AdminCohortChallengeAccessesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    @cohort = @savings_cohort
    @cohort.update!(savings_challenge_enabled: false, savings_challenge_release_hold: true)
    @admin = persona_user(role: "admin")
  end

  test "status is not set up until a savings release is launched, then ready" do
    assert_equal "not_set_up", status_for(@admin).fetch("state")
    assert_includes status_for(@admin).fetch("blockers").join, "Prepare and launch a version"
    with_savings_runtime do
      status = status_for(@admin)
      assert_equal "ready", status.fetch("state")
      assert_equal "Ready to open", status.fetch("label")
      assert_empty status.fetch("blockers")
      assert_equal 30, status.fetch("capacity")
    end
  end

  test "admin opens with a reason, participants then pass the real access policy, and the change is audited" do
    with_savings_runtime do
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { policy_call }
      post open_path, params: body("Pilot kickoff approved", "ready"), headers: headers("open-1"), as: :json
      assert_response :created
      assert_equal "open", response.parsed_body.dig("savings_challenge", "state")
      @cohort.reload
      assert @cohort.savings_challenge_enabled
      refute @cohort.savings_challenge_release_hold
      assert policy_call
      event = @cohort.cohort_challenge_access_events.sole
      assert_equal [ "open", "ready", "open", @admin.id, "platform_admin", "Pilot kickoff approved" ],
        [ event.action, event.from_state, event.to_state, event.actor_user_id, event.actor_role_snapshot, event.reason ]
      assert_equal [ false, true, true, false ], [ event.enabled_before, event.hold_before, event.enabled_after, event.hold_after ]
      assert_equal @cohort.active_cohort_release_id, event.cohort_release_id
      refute event.update(reason: "Edited later")
      assert_raises(ActiveRecord::StatementInvalid) { CohortChallengeAccessEvent.transaction(requires_new: true) { CohortChallengeAccessEvent.where(id: event.id).update_all(reason: "Edited later") } }
      assert_raises(ActiveRecord::StatementInvalid) { CohortChallengeAccessEvent.transaction(requires_new: true) { CohortChallengeAccessEvent.where(id: event.id).delete_all } }
      assert_equal "Pilot kickoff approved", event.reload.reason
    end
  end

  test "pause always works, reopening needs a fresh state, and replays are idempotent" do
    with_savings_runtime do
      post open_path, params: body("Open for the pilot", "ready"), headers: headers("open-a"), as: :json
      assert_response :created
      assert_no_difference -> { @cohort.cohort_challenge_access_events.count } do
        post open_path, params: body("Open for the pilot", "ready"), headers: headers("open-a"), as: :json
      end
      assert_response :ok
      assert response.parsed_body.fetch("replayed")
      post open_path, params: body("A different reason", "ready"), headers: headers("open-a"), as: :json
      assert_response :conflict

      post pause_path, params: body("Pausing to fix a problem"), headers: headers("pause-a"), as: :json
      assert_response :created
      assert_equal "paused", response.parsed_body.dig("savings_challenge", "state")
      assert @cohort.reload.savings_challenge_release_hold
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { policy_call }

      post open_path, params: body("Resume the pilot", "open"), headers: headers("open-b"), as: :json
      assert_response :conflict
      post open_path, params: body("Resume the pilot", "paused"), headers: headers("open-b"), as: :json
      assert_response :created
      assert_equal %w[open pause open], @cohort.cohort_challenge_access_events.order(:id).pluck(:action)
    end
  end

  test "pausing a cohort that is not open is a no-op success and records no event" do
    with_savings_runtime do
      post pause_path, params: body("Pause before opening"), headers: headers("pause-ready"), as: :json
      assert_response :ok
      assert_equal "ready", response.parsed_body.dig("savings_challenge", "state")
      post open_path, params: body("Open for the pilot", "ready"), headers: headers("open-n"), as: :json
      post pause_path, params: body("Pause for a fix"), headers: headers("pause-n1"), as: :json
      post pause_path, params: body("Pause again"), headers: headers("pause-n2"), as: :json
      assert_response :ok
      assert_equal "paused", response.parsed_body.dig("savings_challenge", "state")
      assert_equal %w[open pause], @cohort.cohort_challenge_access_events.order(:id).pluck(:action)
    end
  end

  test "pause is allowed even when the cohort is archived or the release is no longer a savings release" do
    with_savings_runtime do
      post open_path, params: body("Open for the pilot", "ready"), headers: headers("open-x"), as: :json
      @cohort.update!(status: "archived")
      assert_equal "open", status_for(@admin).fetch("state")
      post pause_path, params: body("Closing out the pilot"), headers: headers("pause-x"), as: :json
      assert_response :created
      assert @cohort.reload.savings_challenge_release_hold
    end
  end

  test "opening is refused with a plain reason unless a savings release is launched and the cohort is enrolling or active" do
    post open_path, params: body("Try to open early", "not_set_up"), headers: headers("early"), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("error"), "Prepare and launch a version first"
    refute @cohort.reload.savings_challenge_enabled

    with_savings_runtime do
      @cohort.update!(status: "draft")
      post open_path, params: body("Try while draft", "not_set_up"), headers: headers("draft"), as: :json
      assert_response :unprocessable_entity
      assert_includes response.parsed_body.fetch("error"), "Enrolling or Active"
    end

    household = Cohort.create!(name: "Household #{SecureRandom.hex(4)}", status: "enrolling", created_by_user: @savings_owner)
    configuration = household.cohort_experience_configuration
    configuration.update!(draft_config: CohortExperience::Schema::LEGACY_CONFIG, last_edited_by_user: @admin)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: @admin)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id)
    CohortReleases::Sealer.new(cohort: household, actor: nil, publication_source: "system").call!(request_key: "household-runtime")
    CohortReleases::RuntimeActivator.new(cohort: household.reload).call!
    assert household.reload.active_cohort_release_id
    post "/api/v1/admin/cohorts/#{household.id}/challenge_access/open", params: body("Try the wrong experience", "not_set_up"), headers: headers("wrong"), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("error"), "not the Savings Challenge"
    refute household.reload.savings_challenge_enabled
    assert_empty @cohort.cohort_challenge_access_events
  end

  test "only platform administrators can change it; owners, coaches and participants cannot" do
    with_savings_runtime do
      owner = persona_user(role: "coach")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
      [ owner, @savings_user ].each do |user|
        post open_path, params: body("Not allowed to open", "ready"), headers: { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => "deny-#{user.id}" }, as: :json
        assert_response :forbidden
        post pause_path, params: body("Not allowed to pause"), headers: { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => "deny-p-#{user.id}" }, as: :json
        assert_response :forbidden
      end
      post open_path, params: body("Owner in workspace", "ready"), headers: { "Authorization" => "Bearer test_token_#{owner.id}", "X-Coach-Workspace-Id" => workspace.id.to_s, "Idempotency-Key" => "deny-ws" }, as: :json
      assert_response :forbidden
      assert_empty @cohort.cohort_challenge_access_events
      refute @cohort.reload.savings_challenge_enabled
    end
  end

  test "a reason and an idempotency key are required" do
    with_savings_runtime do
      post open_path, params: body("no", "ready"), headers: headers("short"), as: :json
      assert_response :unprocessable_entity
      post open_path, params: body("A real reason", "ready"), headers: { "Authorization" => "Bearer test_token_#{@admin.id}" }, as: :json
      assert_response :unprocessable_entity
      assert_empty @cohort.cohort_challenge_access_events
    end
  end

  test "program owners see the status on the cohort payload but cannot change it" do
    with_savings_runtime do
      owner = persona_user(role: "coach")
      workspace = @cohort.coach_workspace
      workspace.coach_workspace_memberships.create!(user: owner, role: "owner")
      get "/api/v1/admin/cohorts/#{@cohort.id}", headers: { "Authorization" => "Bearer test_token_#{owner.id}", "X-Coach-Workspace-Id" => workspace.id.to_s }
      assert_response :success
      challenge = response.parsed_body.dig("cohort", "savings_challenge")
      assert_equal "ready", challenge.fetch("state")
      refute challenge.fetch("can_change")
      get "/api/v1/admin/cohorts/#{@cohort.id}", headers: { "Authorization" => "Bearer test_token_#{@admin.id}" }
      assert response.parsed_body.dig("cohort", "savings_challenge", "can_change")
    end
  end

  private

  def open_path = "/api/v1/admin/cohorts/#{@cohort.id}/challenge_access/open"
  def pause_path = "/api/v1/admin/cohorts/#{@cohort.id}/challenge_access/pause"
  def headers(key) = { "Authorization" => "Bearer test_token_#{@admin.id}", "Idempotency-Key" => key }

  def body(reason, expected_state = nil)
    { challenge_access: { reason: reason, expected_state: expected_state }.compact }
  end

  def status_for(user)
    get "/api/v1/admin/cohorts/#{@cohort.id}", headers: { "Authorization" => "Bearer test_token_#{user.id}" }
    assert_response :success
    response.parsed_body.dig("cohort", "savings_challenge")
  end

  def policy_call
    SavingsChallenge::AccessPolicy.new(household: @savings_household, user: @savings_user, cohort: @cohort.reload).call!
  end
end
