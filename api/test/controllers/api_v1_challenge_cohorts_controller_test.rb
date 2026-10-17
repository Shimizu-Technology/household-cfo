require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1ChallengeCohortsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    setup_savings_context
    with_daily_operations { savings_enroll; savings_plan; savings_approve(savings_draft(12345)); daily_check_in("no_spend") }
  end
  teardown { travel_back }

  test "coach roster exposes completion and help metadata without private financial values" do
    get path("participants"), headers: auth(@savings_owner)
    assert_response :success
    row = response.parsed_body.fetch("records").sole
    assert row.dig("check_in", "completed")
    assert_equal @savings_enrollment.id, row["enrollment_id"]
    assert_equal @savings_owner.id, response.parsed_body.dig("actor_scope", "user_id")
    assert_not response.body.match?(/12345|reported_cents|target_cents|no_spend|merchant|feeling|spending_state/)
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get path("participants"), headers: auth(@savings_owner)
    assert_response :success
    assert_nil response.parsed_body.fetch("records").sole.dig("check_in", "completed")
    get "/api/v1/shared_challenges/#{@savings_enrollment.id}/scopes", headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "participant unrelated admin and removed staff cannot inspect the roster or report" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "unrelated-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    [ @savings_user, admin ].each do |actor|
      get path("participants"), headers: auth(actor)
      assert_response :forbidden
      get path("sponsor_exports"), headers: auth(actor)
      assert_response :forbidden
    end
    CoachWorkspaceMembership.where(user: @savings_owner).delete_all
    get path("participants"), headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "admin creating a program for a named coach and a group gives that coach the roster but not the admin" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "owner-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    mel = User.create!(clerk_id: SecureRandom.uuid, email: "mel-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    post "/api/v1/admin/coach_workspaces", params: { coach_workspace: { name: "Mel program", owner_email: mel.email,
      coach_profile: { display_name: "Mel", title: "Coach", bio: "" } } }, headers: auth(admin), as: :json
    assert_response :created
    workspace_id = response.parsed_body.dig("coach_workspace", "id")
    post "/api/v1/admin/cohorts", params: { cohort: { name: "Mel group", status: "enrolling" } },
      headers: auth(admin).merge("X-Coach-Workspace-Id" => workspace_id.to_s), as: :json
    assert_response :created
    cohort_id = response.parsed_body.dig("cohort", "id")
    assert_equal "coach", CohortMembership.find_by!(cohort_id: cohort_id, user: mel).role
    assert_nil CohortMembership.find_by(cohort_id: cohort_id, user: admin)

    get "/api/v1/challenge_cohorts/#{cohort_id}/participants", headers: auth(mel)
    assert_response :success
    get "/api/v1/challenge_cohorts/#{cohort_id}/participants", headers: auth(admin)
    assert_response :forbidden
    assert_includes response.parsed_body.fetch("errors").first, "Ask a platform admin to add you as a coach"
  end

  test "an owner named after groups exist is added to existing groups but not archived ones" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "late-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    mel = User.create!(clerk_id: SecureRandom.uuid, email: "late-mel-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspace.create!(name: "Late owner", slug: "late-#{SecureRandom.hex(4)}", created_by_user: admin)
    live = Cohort.create!(name: "Live", status: "enrolling", created_by_user: admin, coach_workspace: workspace)
    archived = Cohort.create!(name: "Old", status: "archived", created_by_user: admin, coach_workspace: workspace)
    CoachWorkspaces::Collaborators.new(workspace: workspace, actor: admin).add(email: mel.email, role: "owner")
    assert CohortMembership.exists?(cohort: live, user: mel, role: "coach")
    assert_not CohortMembership.exists?(cohort: archived, user: mel)
  end

  test "demoting an owner removes only the auto-granted coach rows, never manual ones" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "demote-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    mel = User.create!(clerk_id: SecureRandom.uuid, email: "demote-mel-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    manual = User.create!(clerk_id: SecureRandom.uuid, email: "demote-manual-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspace.create!(name: "Demote", slug: "demote-#{SecureRandom.hex(4)}", created_by_user: admin)
    group = Cohort.create!(name: "Demote group", status: "enrolling", created_by_user: admin, coach_workspace: workspace)
    collaborators = CoachWorkspaces::Collaborators.new(workspace: workspace, actor: admin)

    keeper = User.create!(clerk_id: SecureRandom.uuid, email: "demote-keeper-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    collaborators.add(email: keeper.email, role: "owner")
    collaborators.add(email: mel.email, role: "owner")
    assert CohortMembership.find_by!(cohort: group, user: mel).owner_managed?
    get "/api/v1/challenge_cohorts/#{group.id}/participants", headers: auth(mel)
    assert_response :success

    %w[editor viewer].each do |role|
      current = workspace.coach_workspace_memberships.find_by!(user: mel)
      collaborators.change(id: current.id, role: "owner", expected_role: current.role) unless current.role == "owner"
      assert CohortMembership.exists?(cohort: group, user: mel)
      collaborators.change(id: workspace.coach_workspace_memberships.find_by!(user: mel).id, role: role, expected_role: "owner")
      assert_not CohortMembership.exists?(cohort: group, user: mel), role
      get "/api/v1/challenge_cohorts/#{group.id}/participants", headers: auth(mel)
      assert_response :forbidden
    end

    CohortMembership.create!(cohort: group, user: manual, role: "coach")
    manual_member = workspace.coach_workspace_memberships.find_by!(user: manual)
    collaborators.change(id: manual_member.id, role: "owner", expected_role: manual_member.role)
    assert_not CohortMembership.find_by!(cohort: group, user: manual).owner_managed?
    collaborators.change(id: manual_member.id, role: "viewer", expected_role: "owner")
    assert CohortMembership.exists?(cohort: group, user: manual, role: "coach")
  end

  test "an admin's explicit coach assignment replaces the owner-managed mark and survives demotion" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "explicit-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    mel = User.create!(clerk_id: SecureRandom.uuid, email: "explicit-mel-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    keeper = User.create!(clerk_id: SecureRandom.uuid, email: "explicit-keeper-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspace.create!(name: "Explicit", slug: "explicit-#{SecureRandom.hex(4)}", created_by_user: admin)
    group = Cohort.create!(name: "Explicit group", status: "enrolling", created_by_user: admin, coach_workspace: workspace)
    collaborators = CoachWorkspaces::Collaborators.new(workspace: workspace, actor: admin)
    collaborators.add(email: keeper.email, role: "owner")
    collaborators.add(email: mel.email, role: "owner")
    assert CohortMembership.find_by!(cohort: group, user: mel).owner_managed?

    patch "/api/v1/admin/users/#{mel.id}", params: { user: { role: "coach", cohort_ids: [ group.id ] } },
      headers: auth(admin).merge("X-Coach-Workspace-Id" => workspace.id.to_s), as: :json
    assert_response :success
    assert_not CohortMembership.find_by!(cohort: group, user: mel).owner_managed?

    current = workspace.coach_workspace_memberships.find_by!(user: mel)
    collaborators.change(id: current.id, role: "viewer", expected_role: "owner")
    assert CohortMembership.exists?(cohort: group, user: mel, role: "coach")
  end

  test "owner cohort access re-checks ownership and tolerates duplicates" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "race-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    mel = User.create!(clerk_id: SecureRandom.uuid, email: "race-mel-#{SecureRandom.hex(4)}@example.com", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspace.create!(name: "Race", slug: "race-#{SecureRandom.hex(4)}", created_by_user: admin)
    group = Cohort.create!(name: "Race group", status: "enrolling", created_by_user: admin, coach_workspace: workspace)
    workspace.coach_workspace_memberships.create!(user: mel, role: "viewer")

    CoachWorkspaces::OwnerCohortAccess.ensure_coach!(group, mel)
    assert_not CohortMembership.exists?(cohort: group, user: mel), "a user who is no longer an owner gets no row"

    workspace.coach_workspace_memberships.find_by!(user: mel).update!(role: "owner")
    2.times { CoachWorkspaces::OwnerCohortAccess.ensure_coach!(group, mel) }
    assert_equal 1, CohortMembership.where(cohort: group, user: mel).count
  end

  test "a person who may not seal reports gets 403 before any validation error" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "seal-denied-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    [ { checkpoint_day: 30, accepted: true, department: "one person" }, { checkpoint_day: 7 }, {} ].each do |input|
      post path("sponsor_exports"), params: input, headers: auth(admin), as: :json
      assert_response :forbidden
    end
    CoachWorkspaceMembership.find_by!(user: @savings_owner).update!(role: "editor")
    post path("sponsor_exports"), params: { checkpoint_day: 7 }, headers: auth(@savings_owner), as: :json
    assert_response :forbidden
  end

  test "fixed report explicit approval is repeatable suppressed and rejects filters and consent changes" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    input = { checkpoint_day: 30, accepted: true }
    post path("sponsor_exports"), params: input.merge(department: "one person"), headers: auth(@savings_owner), as: :json
    assert_response :unprocessable_entity
    assert_empty ChallengeSponsorExport.all
    2.times do
      post path("sponsor_exports"), params: input, headers: auth(@savings_owner), as: :json
      assert_response :success
      assert response.parsed_body.dig("report", "suppressed")
      assert_empty response.parsed_body.dig("report", "bands")
      assert_not response.body.match?(/enrollment_id|reported_cents|private_provenance|12345/)
    end
    assert_equal 1, ChallengeSponsorExport.count
    id = ChallengeSponsorExport.sole.id
    get path("sponsor_exports/#{id}"), params: { department: "one person" }, headers: auth(@savings_owner)
    assert_response :unprocessable_entity
    get path("sponsor_exports/#{id}.csv"), headers: auth(@savings_owner)
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_not response.body.match?(/enrollment_id|reported_cents|12345/)
    @savings_enrollment.reload.update!(status: "withdrawn")
    get path("sponsor_exports/#{id}"), headers: auth(@savings_owner)
    assert_response :forbidden
    assert_equal 1, ChallengeSponsorExport.count
  end

  test "sharing scope metadata never returns private contents and rechecks expiry" do
    route = "/api/v1/shared_challenges/#{@savings_enrollment.id}/scopes"
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_equal false, response.parsed_body["summary_available"]
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    message = session.chat_messages.create!(role: "user", content: "Synthetic private feelings secret", cohort: @savings_cohort, cohort_release: @savings_release)
    op = HouseholdFinance::Operations::Privacy::ConsentSet.new(@savings_household, user: @savings_user)
    op.execute!(op.prepare(enrollment_id: @savings_enrollment.id, kind: "selected_details", recipient_user_id: @savings_owner.id,
      granted: true, selected_records: [ { record_type: "chat_message", record_id: message.id } ], expires_at: 1.hour.from_now.iso8601,
      policy_version: "challenge_privacy_v1", expected_grant_id: nil, expected_lock_version: 0), source: "manual_ui")
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_equal [ { "record_type" => "chat_message", "record_id" => message.id } ], response.parsed_body["selected_records"]
    assert_not_includes response.body, message.content
    travel 2.hours
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_empty response.parsed_body["selected_records"]
  end

  private
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def path(suffix) = "/api/v1/challenge_cohorts/#{@savings_cohort.id}/#{suffix}"
end
