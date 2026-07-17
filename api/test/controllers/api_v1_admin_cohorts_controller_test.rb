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
    cohort = Cohort.find_by!(name: "Tuesday Pilot")
    cohort.cohort_memberships.create!(user: participant, role: "participant")

    get "/api/v1/admin/cohorts", headers: auth_headers(admin)

    assert_response :success
    body = JSON.parse(response.body)
    row = body.fetch("cohorts").find { |item| item.fetch("name") == "Tuesday Pilot" }
    assert_equal "enrolling", row.fetch("status")
    assert_equal 1, row.fetch("member_count")
    assert_equal 1, row.fetch("participant_count")
  end

  test "cohort index returns setup complete counts without loading full snapshots" do
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
