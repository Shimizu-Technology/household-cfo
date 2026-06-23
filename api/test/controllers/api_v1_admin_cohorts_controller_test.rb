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
