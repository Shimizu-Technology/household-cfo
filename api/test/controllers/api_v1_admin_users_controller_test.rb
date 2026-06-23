require "test_helper"

class ApiV1AdminUsersControllerTest < ActionDispatch::IntegrationTest
  test "admin users endpoint requires authentication" do
    get "/api/v1/admin/users"

    assert_response :unauthorized
  end

  test "admin users endpoint rejects non-staff users" do
    participant = create_user(email: "participant@example.com", role: "participant")

    get "/api/v1/admin/users", headers: auth_headers(participant)

    assert_response :forbidden
  end

  test "admin can create staff invited users" do
    admin = create_user(email: "owner@example.com", role: "admin")

    post "/api/v1/admin/users",
         params: {
           user: {
             email: "new-coach@example.com",
             first_name: "New",
             last_name: "Coach",
             role: "coach"
           }
         },
         headers: auth_headers(admin),
         as: :json

    assert_response :created
    body = JSON.parse(response.body).fetch("user")
    assert_equal "new-coach@example.com", body.fetch("email")
    assert_equal "coach", body.fetch("role")
    assert_equal "pending", body.fetch("invitation_status")
  end

  test "staff can create pending invited users" do
    coach = create_user(email: "coach@example.com", role: "coach")

    post "/api/v1/admin/users",
         params: {
           user: {
             email: "new-participant@example.com",
             first_name: "New",
             last_name: "Participant",
             role: "participant"
           }
         },
         headers: auth_headers(coach),
         as: :json

    assert_response :created
    body = JSON.parse(response.body).fetch("user")
    assert_equal "new-participant@example.com", body.fetch("email")
    assert_equal "participant", body.fetch("role")
    assert_equal "pending", body.fetch("invitation_status")
  end

  test "coach cannot create admin invited users" do
    coach = create_user(email: "limited-coach@example.com", role: "coach")

    post "/api/v1/admin/users",
         params: { user: { email: "promoted@example.com", role: "admin" } },
         headers: auth_headers(coach),
         as: :json

    assert_response :forbidden
    assert_equal "Role assignment not permitted", JSON.parse(response.body).fetch("error")
    assert_nil User.find_by(email: "promoted@example.com")
  end

  test "staff cannot create users with invalid roles" do
    admin = create_user(email: "admin@example.com", role: "admin")

    post "/api/v1/admin/users",
         params: { user: { email: "bad-role@example.com", role: "super_admin" } },
         headers: auth_headers(admin),
         as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Role is not valid"
  end

  test "admin can invite a participant directly into a cohort" do
    admin = create_user(email: "cohort-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Tuesday Pilot", status: "enrolling", created_by_user: admin)

    post "/api/v1/admin/users",
         params: {
           user: {
             email: "pilot@example.com",
             first_name: "Pilot",
             last_name: "Participant",
             role: "participant",
             cohort_id: cohort.id
           }
         },
         headers: auth_headers(admin),
         as: :json

    assert_response :created
    user = User.find_by!(email: "pilot@example.com")
    assert_equal admin, user.invited_by_user
    assert_equal cohort, user.cohorts.first
    body = JSON.parse(response.body).fetch("user")
    assert_equal [ "Tuesday Pilot" ], body.fetch("cohorts").map { |membership| membership.fetch("cohort").fetch("name") }
  end

  test "admin can update a user's role status and cohort assignment" do
    admin = create_user(email: "owner-2@example.com", role: "admin")
    user = create_user(email: "managed@example.com", role: "participant")
    first_cohort = Cohort.create!(name: "First Pilot", status: "draft", created_by_user: admin)
    second_cohort = Cohort.create!(name: "Second Pilot", status: "enrolling", created_by_user: admin)
    user.cohort_memberships.create!(cohort: first_cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "coach", invitation_status: "pending", cohort_ids: [ second_cohort.id ] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    user.reload
    assert_equal "coach", user.role
    assert_equal "accepted", user.invitation_status
    assert_equal [ second_cohort ], user.cohorts.to_a
    assert_equal "coach", user.cohort_memberships.first.role
  end

  test "admin can preserve multiple cohort assignments on user save" do
    admin = create_user(email: "multi-owner@example.com", role: "admin")
    user = create_user(email: "multi-managed@example.com", role: "participant")
    first_cohort = Cohort.create!(name: "First Multi Pilot", status: "draft", created_by_user: admin)
    second_cohort = Cohort.create!(name: "Second Multi Pilot", status: "enrolling", created_by_user: admin)
    user.cohort_memberships.create!(cohort: first_cohort, role: "participant")
    user.cohort_memberships.create!(cohort: second_cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "participant", cohort_ids: [ first_cohort.id, second_cohort.id ] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    assert_equal [ first_cohort, second_cohort ].map(&:id).sort, user.reload.cohorts.pluck(:id).sort
  end

  test "admin user save without cohort params does not remove existing cohort assignments" do
    admin = create_user(email: "preserve-owner@example.com", role: "admin")
    user = create_user(email: "preserve-managed@example.com", role: "participant")
    first_cohort = Cohort.create!(name: "First Preserve Pilot", status: "draft", created_by_user: admin)
    second_cohort = Cohort.create!(name: "Second Preserve Pilot", status: "enrolling", created_by_user: admin)
    user.cohort_memberships.create!(cohort: first_cohort, role: "participant")
    user.cohort_memberships.create!(cohort: second_cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "coach" } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    assert_equal [ first_cohort, second_cohort ].map(&:id).sort, user.reload.cohorts.pluck(:id).sort
    assert_equal [ "coach" ], user.cohort_memberships.distinct.pluck(:role)
  end

  test "admin cannot revoke their own admin access" do
    admin = create_user(email: "self-admin@example.com", role: "admin")

    patch "/api/v1/admin/users/#{admin.id}",
          params: { user: { invitation_status: "revoked" } },
          headers: auth_headers(admin),
          as: :json

    assert_response :forbidden
    assert_equal "You cannot remove your own admin access", JSON.parse(response.body).fetch("error")
    assert_equal "accepted", admin.reload.invitation_status
  end

  test "coach cannot update an admin user" do
    coach = create_user(email: "coach-limited@example.com", role: "coach")
    admin = create_user(email: "protected-admin@example.com", role: "admin")

    patch "/api/v1/admin/users/#{admin.id}",
          params: { user: { role: "participant" } },
          headers: auth_headers(coach),
          as: :json

    assert_response :forbidden
    assert_equal "User update not permitted", JSON.parse(response.body).fetch("error")
    assert_equal "admin", admin.reload.role
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
