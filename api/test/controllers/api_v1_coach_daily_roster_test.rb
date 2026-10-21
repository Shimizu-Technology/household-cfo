require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1CoachDailyRosterTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    setup_savings_context
    with_daily_operations { savings_enroll; savings_plan; savings_approve(savings_draft(12345)); daily_check_in("no_spend") }
  end
  teardown { travel_back }

  test "daily read is scoped to this cohort coach and current program membership" do
    stranger = User.create!(clerk_id: SecureRandom.uuid, email: "stranger@example.invalid", role: "coach", invitation_status: "accepted")
    @savings_cohort.coach_workspace.coach_workspace_memberships.create!(user: stranger, role: "viewer")
    workspace = CoachWorkspace.create!(name: "Other program", slug: "other-daily", created_by_user: stranger)
    workspace.coach_workspace_memberships.create!(user: stranger, role: "owner")
    other = Cohort.create!(name: "Another coach group", status: "enrolling", created_by_user: stranger, coach_workspace: workspace)
    get "/api/v1/challenge_cohorts/#{other.id}/participants", params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :forbidden
    [ stranger, @savings_user ].each do |actor|
      get route, params: { view: "daily" }, headers: auth(actor)
      assert_response :forbidden
    end
    get route, params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    CoachWorkspaceMembership.where(user: @savings_owner).delete_all
    get route, params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "Daily invitation capability matches the existing guarded owner form" do
    get route, params: { view: "daily" }, headers: auth(@savings_owner)
    assert_equal true, response.parsed_body["can_invite"]
    CoachWorkspaceMembership.find_by!(user: @savings_owner, coach_workspace: @savings_cohort.coach_workspace).update!(role: "editor")
    get route, params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :success
    assert_equal false, response.parsed_body["can_invite"]
  end

  test "help first, all-group search and filters contain no financial values or private messages" do
    @savings_user.update!(first_name: "Zoe")
    22.times { |i| add_person("Ana #{i}") }
    ticket = ChallengeSupportTicket.create!(savings_enrollment: @savings_enrollment, household: @savings_household,
      participant_user: @savings_user, recipient_user: @savings_owner, message: "Secret private message 98765", issue_kind: "coaching", status: "open")
    get route, params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :success
    body = response.parsed_body
    assert_equal 20, body["records"].size
    assert_equal "Zoe", body["records"].first.dig("participant", "name")
    assert_equal ticket.id, body["records"].first["help_requests"].sole["id"]
    assert_equal 23, body.dig("counts", "all")
    assert_equal 1, body.dig("counts", "checked_in")
    assert_equal 1, body.dig("counts", "needs_help")
    assert_not response.body.match?(/12345|98765|target_cents|reported_cents|merchant|spending_state|no_spend|Secret private/)
    get route, params: { view: "daily", search: "Ana 21" }, headers: auth(@savings_owner)
    assert_equal "Ana 21", response.parsed_body["records"].sole.dig("participant", "name")
    get route, params: { view: "daily", filter: "checked_in" }, headers: auth(@savings_owner)
    assert_equal @savings_user.id, response.parsed_body["records"].sole.dig("participant", "id")
    get route, params: { view: "daily", offset: "20" }, headers: auth(@savings_owner)
    assert_equal 3, response.parsed_body["records"].length
  end

  test "shared item hints expire and never share amounts or records without current grants" do
    grant = ChallengeSupportTicket.create!(savings_enrollment: @savings_enrollment, household: @savings_household,
      participant_user: @savings_user, recipient_user: @savings_owner, message: "Help", issue_kind: "coaching", status: "resolved")
    access = ChallengeSupportAccess.create!(savings_enrollment: @savings_enrollment, household: @savings_household,
      participant_user: @savings_user, recipient_user: @savings_owner, challenge_support_ticket: grant, reason: "Help", expires_at: 1.hour.from_now,
      selected_records: [ { record_type: "savings_plan_version", record_id: @savings_enrollment.reload.current_accepted_plan_version_id } ])
    get route, params: { view: "daily", filter: "needs_help" }, headers: auth(@savings_owner)
    assert_equal [ "savings_plan_version" ], response.parsed_body["records"].sole["shared_items"]
    assert_not_includes response.body, "target_cents"
    access.update!(revoked_at: Time.current)
    get route, params: { view: "daily", filter: "needs_help" }, headers: auth(@savings_owner)
    assert_empty response.parsed_body["records"]
    # Existing exact-record read still refuses a revoked support grant.
    get "/api/v1/shared_challenges/#{@savings_enrollment.id}/selected", params: { record_type: "savings_plan_version", record_id: @savings_enrollment.reload.current_accepted_plan_version_id, support_access_id: access.id }, headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "household roster includes pending invitees and setup help but never savings check-ins" do
    @savings_cohort.update!(savings_challenge_enabled: false)
    elena = add_person("Elena")
    household = HouseholdFinance::WorkspaceResolver.new(elena).household
    member = @savings_cohort.cohort_memberships.find_by!(user: elena)
    # Household scope uses a separate cohort without a savings enrollment/runtime.
    group = Cohort.create!(name: "Household", created_by_user: @savings_owner, status: "enrolling")
    member = CohortMembership.create!(cohort: group, user: elena, role: "participant")
    SetupSupportRequest.create!(household: household, requested_by_user: elena, cohort: group,
      participant_membership_id: member.id, participant_membership_started_at: member.created_at, reason: "upload_problem", status: "requested")
    invited = add_person("Fiona", accepted: false, cohort: group)
    get "/api/v1/challenge_cohorts/#{group.id}/participants", params: { view: "daily" }, headers: auth(@savings_owner)
    assert_response :success
    body = response.parsed_body
    assert_equal "household", body["program_type"]
    assert_equal [ elena.id, invited.id ], body["records"].map { |row| row.dig("participant", "id") }
    assert_equal "upload_problem", body["records"].first["setup_help"].sole["reason"]
    assert_equal "invited", body["records"].last["membership_status"]
    assert body["records"].all? { |row| row["enrollment_id"].nil? && row["check_in"].nil? }
    member.destroy!
    CohortMembership.create!(cohort: group, user: elena, role: "participant")
    get "/api/v1/challenge_cohorts/#{group.id}/participants", params: { view: "daily", filter: "needs_help" }, headers: auth(@savings_owner)
    assert_empty response.parsed_body["records"], "An old request cannot follow a replacement membership"
  end

  private
  def route = "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants"
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def add_person(name, accepted: true, cohort: @savings_cohort)
    user = User.create!(clerk_id: "#{accepted ? 'clerk' : 'pending'}_#{SecureRandom.uuid}", email: "#{SecureRandom.hex(6)}@example.invalid", first_name: name, role: "participant", invitation_status: accepted ? "accepted" : "pending")
    CohortMembership.create!(cohort: cohort, user: user, role: "participant")
    user
  end
end
