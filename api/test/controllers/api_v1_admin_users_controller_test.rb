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
