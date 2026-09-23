require "test_helper"

class ApiV1AdminCohortsControllerTest < ActionDispatch::IntegrationTest
  test "cohorts endpoint requires admin access" do
    participant = create_user(email: "participant@example.com", role: "participant")

    get "/api/v1/admin/cohorts", headers: auth_headers(participant)

    assert_response :forbidden
  end

  test "admin can create and list cohorts with membership counts" do
    admin = create_user(email: "admin@example.com", role: "admin")
    participant = create_user(email: "member@example.com", role: "participant")

    post "/api/v1/admin/cohorts",
         params: {
           cohort: {
             name: "Tuesday Pilot",
             status: "enrolling",
             starts_on: "2026-06-23",
             ends_on: "2026-07-21",
             notes: "First local test group"
           }
         },
         headers: auth_headers(admin),
         as: :json

    assert_response :created
    created_payload = JSON.parse(response.body).fetch("cohort")
    assert_equal 0, created_payload.fetch("setup_complete_count")
    assert_not created_payload.key?("members")
    cohort = Cohort.find_by!(name: "Tuesday Pilot")
    cohort.cohort_memberships.create!(user: participant, role: "participant")

    get "/api/v1/admin/cohorts", headers: auth_headers(admin)

    assert_response :success
    body = JSON.parse(response.body)
    row = body.fetch("cohorts").find { |item| item.fetch("name") == "Tuesday Pilot" }
    assert_equal "enrolling", row.fetch("status")
    assert_equal 1, row.fetch("member_count")
    assert_equal 1, row.fetch("participant_count")
    assert_equal({
      "available" => true,
      "period_days" => 7,
      "mia_requests" => 0,
      "mia_failures" => 0,
      "average_mia_latency_ms" => nil,
      "uploads" => 0,
      "upload_failures" => 0,
      "participants_active" => 0
    }, row.fetch("operational_summary"))
  end

  test "cohort operations summarize recent safe usage without exposing participant content" do
    admin = create_user(email: "operations-admin@example.com", role: "admin")
    participant = create_user(email: "operations-member@example.com", role: "participant")
    coach = create_user(email: "operations-coach@example.com", role: "coach")
    cohort = Cohort.create!(name: "BOG Operations Pilot", status: "active", created_by_user: admin)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    cohort.cohort_memberships.create!(user: coach, role: "coach")
    household = Household.create!(name: "Private Operations Household", created_by_user: participant)
    household.household_memberships.create!(user: participant, role: "owner")
    household.household_audit_events.create!(
      user: participant,
      actor_type: "system",
      event_type: "mia.request.completed",
      occurred_at: 2.hours.ago,
      metadata: { "duration_ms" => 240, "assistant_characters" => 1_200, "attachment_count" => 1 }
    )
    household.household_audit_events.create!(
      user: participant,
      actor_type: "system",
      event_type: "mia.request.completed",
      occurred_at: 1.hour.ago,
      metadata: { "duration_ms" => 360, "assistant_characters" => 900 }
    )
    household.household_audit_events.create!(
      user: participant,
      actor_type: "system",
      event_type: "mia.request.failed",
      occurred_at: 30.minutes.ago,
      metadata: { "duration_ms" => 50, "error_code" => "Timeout::Error" }
    )
    FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: participant,
      document_kind: "spreadsheet",
      status: "failed",
      filename: "private-budget.csv",
      content_type: "text/csv",
      byte_size: 32,
      checksum_sha256: "e" * 64,
      s3_key: "household-cfo/test/operations-private-budget.csv"
    )
    coach_household = Household.create!(name: "Coach Household", created_by_user: coach)
    coach_household.household_memberships.create!(user: coach, role: "owner")
    coach_household.household_audit_events.create!(
      user: coach,
      actor_type: "system",
      event_type: "mia.request.completed",
      occurred_at: 15.minutes.ago,
      metadata: { "duration_ms" => 9_999 }
    )

    get "/api/v1/admin/cohorts/#{cohort.id}", headers: auth_headers(admin)

    assert_response :success
    body = JSON.parse(response.body)
    summary = body.dig("cohort", "operational_summary")
    assert_equal true, summary.fetch("available")
    assert_equal 7, summary.fetch("period_days")
    assert_equal 2, summary.fetch("mia_requests")
    assert_equal 1, summary.fetch("mia_failures")
    assert_equal 300, summary.fetch("average_mia_latency_ms")
    assert_equal 1, summary.fetch("uploads")
    assert_equal 1, summary.fetch("upload_failures")
    assert_equal 1, summary.fetch("participants_active")
    assert_not_includes response.body, "Private Operations Household"
    assert_not_includes response.body, "private-budget.csv"
    assert_not_includes response.body, "assistant_characters"
    assert_not_includes response.body, "Timeout::Error"
  end

  test "cohort operations report unavailable metrics instead of false zero activity" do
    admin = create_user(email: "operations-unavailable-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Unavailable Operations Pilot", status: "active", created_by_user: admin)

    membership_class = HouseholdMembership.singleton_class
    original_where = membership_class.instance_method(:where)
    membership_class.define_method(:where) { |*| raise ActiveRecord::StatementInvalid, "metrics query unavailable" }

    begin
      get "/api/v1/admin/cohorts/#{cohort.id}", headers: auth_headers(admin)
    ensure
      membership_class.send(:remove_method, :where)
      membership_class.define_method(:where, original_where)
    end

    assert_response :success
    summary = JSON.parse(response.body).dig("cohort", "operational_summary")
    assert_equal false, summary.fetch("available")
    assert_equal 7, summary.fetch("period_days")
    assert_nil summary.fetch("mia_requests")
    assert_nil summary.fetch("mia_failures")
    assert_nil summary.fetch("average_mia_latency_ms")
    assert_nil summary.fetch("uploads")
    assert_nil summary.fetch("upload_failures")
    assert_nil summary.fetch("participants_active")
  end

  test "cohort index and detail use the same setup complete progress result" do
    admin = create_user(email: "setup-count-admin@example.com", role: "admin")
    participant = create_user(email: "setup-count-member@example.com", role: "participant")
    cohort = Cohort.create!(name: "Setup Count Pilot", status: "active", created_by_user: admin)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    household = create_setup_complete_household(user: participant, name: "Setup Household")
    household.household_memberships.create!(user: participant, role: "owner")

    get "/api/v1/admin/cohorts", headers: auth_headers(admin)

    assert_response :success
    row = JSON.parse(response.body).fetch("cohorts").find { |item| item.fetch("name") == "Setup Count Pilot" }
    assert_equal 1, row.fetch("setup_complete_count")

    get "/api/v1/admin/cohorts/#{cohort.id}", headers: auth_headers(admin)

    assert_response :success
    member = JSON.parse(response.body).dig("cohort", "members").find do |item|
      item.dig("user", "id") == participant.id
    end
    assert_equal row.fetch("setup_complete_count"), member.dig("user", "setup_complete") ? 1 : 0
  end

  test "cohort index setup counts use the same first household as user snapshots" do
    admin = create_user(email: "setup-mismatch-admin@example.com", role: "admin")
    participant = create_user(email: "setup-mismatch-member@example.com", role: "participant")
    cohort = Cohort.create!(name: "Setup Mismatch Pilot", status: "active", created_by_user: admin)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    incomplete_household = Household.create!(name: "Incomplete Household", created_by_user: participant)
    complete_household = create_setup_complete_household(user: admin, name: "Complete Later Household")
    first_membership = incomplete_household.household_memberships.create!(user: participant, role: "owner")
    second_membership = complete_household.household_memberships.create!(user: participant, role: "partner")
    first_membership.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    second_membership.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)

    get "/api/v1/admin/cohorts", headers: auth_headers(admin)

    assert_response :success
    row = JSON.parse(response.body).fetch("cohorts").find { |item| item.fetch("name") == "Setup Mismatch Pilot" }
    assert_equal 0, row.fetch("setup_complete_count")
  end

  test "cohort serialization safely ignores a membership whose user is unavailable" do
    admin = create_user(email: "orphan-safe-admin@example.com", role: "admin")
    participant = create_user(email: "orphan-safe-member@example.com", role: "participant")
    cohort = Cohort.create!(name: "Orphan Safe Pilot", status: "active", created_by_user: admin)
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")
    cohort.cohort_memberships.load
    membership.define_singleton_method(:user) { nil }
    controller = Api::V1::Admin::CohortsController.new

    payload = controller.send(:serialize_cohort, cohort, include_members: true)
    setup_counts = controller.send(:setup_complete_counts_for_cohorts, [ cohort ])

    assert_equal 0, payload.fetch(:member_count)
    assert_equal 0, payload.fetch(:participant_count)
    assert_empty payload.fetch(:members)
    assert_equal 0, setup_counts.fetch(cohort.id)
  end

  test "admin can update cohort status and dates" do
    admin = create_user(email: "owner@example.com", role: "admin")
    cohort = Cohort.create!(name: "Draft Pilot", status: "draft", created_by_user: admin)

    patch "/api/v1/admin/cohorts/#{cohort.id}",
          params: { cohort: { name: "Active Pilot", status: "active", starts_on: "2026-06-24" } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    cohort.reload
    assert_equal "Active Pilot", cohort.name
    assert_equal "active", cohort.status
    assert_equal Date.new(2026, 6, 24), cohort.starts_on
  end

  test "cohort create rejects duplicate names" do
    admin = create_user(email: "owner-duplicate@example.com", role: "admin")
    Cohort.create!(name: "Duplicate Pilot", status: "draft", created_by_user: admin)

    post "/api/v1/admin/cohorts",
         params: { cohort: { name: "duplicate pilot", status: "draft" } },
         headers: auth_headers(admin),
         as: :json

    assert_response :unprocessable_entity
    assert JSON.parse(response.body).fetch("errors").any? { |error| error.include?("Name") }
  end

  test "cohort show returns json not found errors" do
    admin = create_user(email: "show-missing-owner@example.com", role: "admin")

    get "/api/v1/admin/cohorts/999999", headers: auth_headers(admin)

    assert_response :not_found
    assert_includes response.media_type, "application/json"
    assert JSON.parse(response.body).fetch("errors").first.include?("Couldn't find Cohort")
  end

  test "cohort show exposes only safe operational progress for each member" do
    admin = create_user(email: "safe-cohort-admin@example.com", role: "admin")
    participant = create_user(email: "safe-cohort-member@example.com", role: "participant")
    cohort = Cohort.create!(name: "Privacy Safe Pilot", status: "active", created_by_user: admin)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    household = create_setup_complete_household(user: participant, name: "Private Household Name")
    household.household_memberships.create!(user: participant, role: "owner")

    get "/api/v1/admin/cohorts/#{cohort.id}", headers: auth_headers(admin)

    assert_response :success
    member = JSON.parse(response.body).dig("cohort", "members").find do |item|
      item.dig("user", "id") == participant.id
    end.fetch("user")

    assert_equal %w[
      email full_name has_pending_review_work id invitation_status invited last_safe_activity_at role
      setup_complete setup_status signed_in
    ], member.keys.sort
    assert_equal "complete", member.fetch("setup_status")
    assert member.fetch("setup_complete")
    assert_not member.key?("household_name")
    assert_not member.key?("profile_completeness")
    assert_not member.key?("readiness")
  end

  test "cohort update returns json not found errors" do
    admin = create_user(email: "update-missing-owner@example.com", role: "admin")

    patch "/api/v1/admin/cohorts/999999",
          params: { cohort: { name: "Missing Pilot" } },
          headers: auth_headers(admin),
          as: :json

    assert_response :not_found
    assert_includes response.media_type, "application/json"
    assert JSON.parse(response.body).fetch("errors").first.include?("Couldn't find Cohort")
  end

  private

  def create_setup_complete_household(user:, name:)
    household = Household.create!(name: name, primary_goal: "Build runway", created_by_user: user)
    household.income_sources.create!(label: "Primary", amount_cents: 500_000)
    household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", amount_cents: 200_000)
    household.accounts.create!(label: "Emergency", account_type: "emergency_fund", balance_cents: 1_000_000)
    household.goals.create!(label: "Runway", goal_type: "runway", target_amount_cents: 2_000_000)
    household
  end

  def create_user(email:, role:)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
