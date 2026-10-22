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

  test "roster query count stays fixed for 1, 10 and 30 enrolled people with approved check-ins" do
    counts = []
    [ 1, 10, 30 ].each do |size|
      while @savings_cohort.cohort_memberships.where(role: "participant").count < size
        person = add_person("Person #{SecureRandom.hex(3)}")
        household = HouseholdFinance::WorkspaceResolver.new(person).household
        membership = @savings_cohort.cohort_memberships.find_by!(user: person)
        enrollment = SavingsEnrollment.create!(@savings_enrollment.attributes.except("id", "created_at", "updated_at", "current_accepted_plan_version_id").merge(
          "user_id" => person.id, "household_id" => household.id, "accepted_cohort_membership_id" => membership.id, "membership_started_at" => membership.created_at))
        SavingsDailyLedger.create!(savings_enrollment: enrollment, sequence: 1)
        head = SavingsDailyCheckIn.create!(savings_enrollment: enrollment, local_on: enrollment.local_today)
        version = SavingsDailyCheckInVersion.create!(savings_daily_check_in: head, savings_enrollment: enrollment,
          daily_sequence: 1, version_number: 1, spending_state: "no_spend", approved_by_user: person, approved_at: Time.current)
        head.update!(current_version: version)
      end
      # Warm immutable release integrity, not an individual participant's data.
      ChallengePrivacy::CoachDailyRoster.new(@savings_cohort.reload, user: @savings_owner).call
      queries = []
      callback = ->(*args) { p = args.last; queries << p[:sql] unless p[:name].in?(%w[SCHEMA TRANSACTION]) || p[:cached] }
      result = nil
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          result = ChallengePrivacy::CoachDailyRoster.new(@savings_cohort.reload, user: @savings_owner).call
        end
      end
      assert_equal size, result[:counts]["checked_in"]
      counts << queries.length
    end
    assert_equal [ counts.first ] * 3, counts, "queries at 1/10/30: #{counts.inspect}"
    assert_operator counts.max, :<=, 30
    puts "W14 enrolled roster queries 1/10/30: #{counts.inspect}"
  end

  test "batch metadata matches single basic read and only hints at currently shared scopes" do
    single = ChallengePrivacy::SharedReader.new(@savings_enrollment, user: @savings_owner)
    batch = -> { ChallengePrivacy::SharedReader.daily_batch(@savings_cohort.reload, user: @savings_owner).fetch(@savings_user.id) }
    assert_equal single.basic, batch.call.except(:shared_items)
    assert_empty batch.call[:shared_items], "No grant cannot expose an item"
    grant = ChallengePrivacyGrant.create!(savings_enrollment: @savings_enrollment, household: @savings_household,
      participant_user: @savings_user, recipient_user: @savings_owner, kind: "selected_details", granted: true, policy_version: "1", expires_at: 1.hour.from_now,
      selected_records: [ { record_type: "savings_plan_version", record_id: @savings_enrollment.reload.current_accepted_plan_version_id } ])
    assert_equal single.shared_scopes[:selected_records].map { |r| r.fetch("record_type") }, batch.call[:shared_items]
    grant.update!(expires_at: 1.minute.ago)
    assert_empty batch.call[:shared_items], "Expired consent cannot expose an item"
    grant.update!(expires_at: 1.hour.from_now, granted: false)
    assert_empty batch.call[:shared_items], "Revoked consent cannot expose an item"
    ChallengePrivacyGrant.create!(savings_enrollment: @savings_enrollment, household: @savings_household,
      participant_user: @savings_user, recipient_user: nil, kind: "sponsor_aggregate", granted: true, policy_version: "1", selected_records: [])
    assert_empty batch.call[:shared_items], "Another grant kind cannot expose a private item"
    outsider = User.create!(clerk_id: SecureRandom.uuid, email: "other-batch@example.invalid", role: "coach", invitation_status: "accepted")
    other = Cohort.create!(name: "Other workspace", created_by_user: outsider, status: "enrolling")
    assert_raises(ChallengePrivacy::Access::Denied) { ChallengePrivacy::SharedReader.daily_batch(@savings_cohort, user: outsider) }
    assert_empty ChallengePrivacy::SharedReader.daily_batch(other, user: outsider), "Another workspace cannot return this participant"
  end

  test "batch attendance matches the single reader for canonical spending and changed links" do
    with_daily_operations do
      @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
      daily_check_in("spending")
      purchase = daily_approve(daily_stage).subject
      reader = ChallengePrivacy::SharedReader.new(@savings_enrollment, user: @savings_owner)
      assert_equal reader.basic[:check_in], ChallengePrivacy::SharedReader.daily_batch(@savings_cohort, user: @savings_owner).fetch(@savings_user.id)[:check_in]
      purchase.household_transaction.update!(merchant: "Independently changed")
      assert_equal false, reader.basic.dig(:check_in, :completed)
      assert_equal reader.basic[:check_in], ChallengePrivacy::SharedReader.daily_batch(@savings_cohort, user: @savings_owner).fetch(@savings_user.id)[:check_in]
    end
  end

  test "batch rechecks withdrawn, paused and replacement membership states" do
    batch = -> { ChallengePrivacy::SharedReader.daily_batch(@savings_cohort.reload, user: @savings_owner) }
    Cohort.find(@savings_cohort.id).update!(savings_challenge_release_hold: true)
    stale = ChallengePrivacy::SharedReader.daily_batch(@savings_cohort, user: @savings_owner)
    assert_equal "unavailable", stale.fetch(@savings_user.id).dig(:check_in, :availability)
    assert_equal ChallengePrivacy::SharedReader.new(@savings_enrollment, user: @savings_owner).basic[:check_in], batch.call.fetch(@savings_user.id)[:check_in]
    @savings_cohort.update!(savings_challenge_release_hold: false)
    @savings_enrollment.update!(status: "withdrawn")
    assert_equal ChallengePrivacy::SharedReader.new(@savings_enrollment, user: @savings_owner).basic[:check_in], batch.call.fetch(@savings_user.id)[:check_in]
    @savings_membership.destroy!
    @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
    assert_empty batch.call
  end

  test "batch refuses a release pointing to another persona than its sealed version" do
    version = Struct.new(:id, :coach_persona_id).new(123, 456)
    release = Struct.new(:id, :cohort_id, :coach_workspace_id, :persona_mode, :coach_persona_id, :coach_persona_version).new(
      123, @savings_cohort.id, @savings_cohort.coach_workspace_id, "published_version", 789, version)
    batch = ChallengePrivacy::SharedReader::DailyBatch.new(@savings_cohort, user: @savings_owner)
    batch.instance_variable_set(:@runtime_valid, {})
    policy = SavingsChallenge::AccessPolicy
    original_policy = policy.method(:release_supports_challenge?)
    original_persona = Mia::RuntimePersona.method(:new)
    policy.define_singleton_method(:release_supports_challenge?) { |_| true }
    Mia::RuntimePersona.define_singleton_method(:new) { |_| Object.new }
    assert_equal false, batch.send(:valid_release?, release)
  ensure
    policy.define_singleton_method(:release_supports_challenge?, original_policy) if original_policy
    Mia::RuntimePersona.define_singleton_method(:new, original_persona) if original_persona
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
