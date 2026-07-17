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
    cohort = Cohort.create!(name: "Coach Pilot", status: "enrolling", created_by_user: admin)

    post "/api/v1/admin/users",
         params: {
           user: {
             email: "new-coach@example.com",
             first_name: "New",
             last_name: "Coach",
             role: "coach",
             cohort_id: cohort.id
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
    admin = create_user(email: "coach-admin@example.com", role: "admin")
    coach = create_user(email: "coach@example.com", role: "coach")
    cohort = Cohort.create!(name: "Participant Pilot", status: "enrolling", created_by_user: admin)
    coach.cohort_memberships.create!(cohort: cohort, role: "coach")

    post "/api/v1/admin/users",
         params: {
           user: {
             email: "new-participant@example.com",
             first_name: "New",
             last_name: "Participant",
             role: "participant",
             cohort_id: cohort.id
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

  test "coach index only returns participants in assigned cohorts" do
    admin = create_user(email: "scope-admin@example.com", role: "admin")
    coach = create_user(email: "scoped-coach@example.com", role: "coach")
    assigned_cohort = Cohort.create!(name: "Assigned Pilot", status: "active", created_by_user: admin)
    other_cohort = Cohort.create!(name: "Other Pilot", status: "active", created_by_user: admin)
    assigned_participant = create_user(email: "assigned-participant@example.com", role: "participant")
    other_participant = create_user(email: "other-participant@example.com", role: "participant")
    coach.cohort_memberships.create!(cohort: assigned_cohort, role: "coach")
    assigned_participant.cohort_memberships.create!(cohort: assigned_cohort, role: "participant")
    other_participant.cohort_memberships.create!(cohort: other_cohort, role: "participant")

    get "/api/v1/admin/users", headers: auth_headers(coach)

    assert_response :success
    emails = JSON.parse(response.body).fetch("users").map { |user| user.fetch("email") }
    assert_equal [ "assigned-participant@example.com" ], emails
  end

  test "coach cannot assign users to unassigned cohorts" do
    admin = create_user(email: "coach-scope-admin@example.com", role: "admin")
    coach = create_user(email: "coach-scope@example.com", role: "coach")
    assigned_cohort = Cohort.create!(name: "Coach Assigned Pilot", status: "active", created_by_user: admin)
    other_cohort = Cohort.create!(name: "Coach Other Pilot", status: "active", created_by_user: admin)
    coach.cohort_memberships.create!(cohort: assigned_cohort, role: "coach")

    post "/api/v1/admin/users",
         params: { user: { email: "outside-scope@example.com", role: "participant", cohort_id: other_cohort.id } },
         headers: auth_headers(coach),
         as: :json

    assert_response :forbidden
    assert_equal "Cohort assignment not permitted", JSON.parse(response.body).fetch("error")
    assert_nil User.find_by(email: "outside-scope@example.com")
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
    assert_equal "failed", user.invitation_email_status
    assert_equal 1, user.invitation_email_attempts.count
    assert_equal "failed", user.invitation_email_attempts.last.status
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("invitation_sent")
    assert_equal "failed", body.fetch("invitation_status")
    assert_equal [ "Tuesday Pilot" ], body.fetch("user").fetch("cohorts").map { |membership| membership.fetch("cohort").fetch("name") }
  end

  test "admin can explicitly create an invite without sending email" do
    admin = create_user(email: "skip-email-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Quiet Pilot", status: "enrolling", created_by_user: admin)

    post "/api/v1/admin/users",
         params: { user: { email: "quiet-pilot@example.com", role: "participant", cohort_id: cohort.id, send_invitation_email: false } },
         headers: auth_headers(admin),
         as: :json

    assert_response :created
    user = User.find_by!(email: "quiet-pilot@example.com")
    assert_equal "skipped", user.invitation_email_status
    assert_equal "skipped", user.invitation_email_attempts.last.status
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("invitation_sent")
    assert_equal "skipped", body.fetch("invitation_status")
  end

  test "admin create invite reactivates a revoked existing user instead of failing uniqueness" do
    admin = create_user(email: "reactivate-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Reactivate Pilot", status: "active", created_by_user: admin)
    user = User.create!(
      clerk_id: "pending_#{SecureRandom.hex(6)}",
      email: "reactivate-me@example.com",
      first_name: "Old",
      last_name: "Name",
      role: "participant",
      invitation_status: "revoked"
    )

    with_user_invite_email_stub(sent: true, status: "sent", provider_message_id: "email_reactivated", error: nil) do
      post "/api/v1/admin/users",
           params: { user: { email: "reactivate-me@example.com", first_name: "New", last_name: "Participant", role: "participant", cohort_id: cohort.id } },
           headers: auth_headers(admin),
           as: :json
    end

    assert_response :success
    assert_equal 1, User.where(email: "reactivate-me@example.com").count
    user.reload
    assert_equal "pending", user.invitation_status
    assert_equal "New", user.first_name
    assert_equal "Participant", user.last_name
    assert_equal [ cohort ], user.cohorts.to_a
    assert_equal "sent", user.invitation_email_status
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("created")
    assert_equal true, body.fetch("reactivated")
    assert_equal true, body.fetch("invitation_sent")
  end

  test "admin create invite adds an existing active user to another cohort" do
    admin = create_user(email: "existing-admin@example.com", role: "admin")
    first_cohort = Cohort.create!(name: "Existing First", status: "active", created_by_user: admin)
    second_cohort = Cohort.create!(name: "Existing Second", status: "active", created_by_user: admin)
    user = create_user(email: "existing-participant@example.com", role: "participant")
    user.cohort_memberships.create!(cohort: first_cohort, role: "participant")

    post "/api/v1/admin/users",
         params: { user: { email: "existing-participant@example.com", role: "participant", cohort_id: second_cohort.id, send_invitation_email: false } },
         headers: auth_headers(admin),
         as: :json

    assert_response :success
    assert_equal [ first_cohort, second_cohort ].map(&:id).sort, user.reload.cohorts.pluck(:id).sort
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("created")
    assert_equal false, body.fetch("reactivated")
  end

  test "admin create invite does not silently change an active user's role" do
    admin = create_user(email: "role-mismatch-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Role Mismatch Pilot", status: "active", created_by_user: admin)
    user = create_user(email: "role-mismatch@example.com", role: "coach")
    user.cohort_memberships.create!(cohort: cohort, role: "coach")

    post "/api/v1/admin/users",
         params: { user: { email: "role-mismatch@example.com", role: "participant", cohort_id: cohort.id } },
         headers: auth_headers(admin),
         as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "This email already belongs to an existing coach user. Update the existing user row to change role."
    assert_equal "coach", user.reload.role
  end

  test "admin invite preserves delivered status when invite audit recording fails" do
    admin = create_user(email: "audit-fallback-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Audit Fallback Pilot", status: "enrolling", created_by_user: admin)

    with_user_invite_email_stub(sent: true, status: "invalid_status", provider_message_id: "email_delivered_123", error: nil) do
      post "/api/v1/admin/users",
           params: { user: { email: "audit-fallback@example.com", role: "participant", cohort_id: cohort.id } },
           headers: auth_headers(admin),
           as: :json
    end

    assert_response :created
    user = User.find_by!(email: "audit-fallback@example.com")
    assert_equal cohort, user.cohorts.first
    assert_empty user.invitation_email_attempts
    assert_equal "sent", user.invitation_email_status
    assert_equal "email_delivered_123", user.invitation_email_provider_id
    assert_not_nil user.last_invite_email_sent_at
    assert_equal admin, user.last_invite_email_sent_by_user
    body = JSON.parse(response.body)
    assert_equal true, body.fetch("invitation_sent")
    assert_equal "sent", body.fetch("invitation_status")
    assert_includes body.fetch("invitation_error"), "delivery audit could not be recorded"
  end

  test "admins can be invited without a cohort but participants cannot" do
    admin = create_user(email: "no-cohort-admin@example.com", role: "admin")

    post "/api/v1/admin/users",
         params: { user: { email: "new-admin@example.com", role: "admin" } },
         headers: auth_headers(admin),
         as: :json

    assert_response :created
    assert_empty User.find_by!(email: "new-admin@example.com").cohorts

    post "/api/v1/admin/users",
         params: { user: { email: "no-cohort-participant@example.com", role: "participant" } },
         headers: auth_headers(admin),
         as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Participant users must be assigned to at least one cohort"
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

  test "admin user update permits safe role status params and ignores unsafe fields" do
    admin = create_user(email: "strong-params-owner@example.com", role: "admin")
    user = create_user(email: "strong-params-user@example.com", role: "participant")
    cohort = Cohort.create!(name: "Strong Params Pilot", status: "draft", created_by_user: admin)
    user.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: {
            user: {
              email: "changed@example.com",
              clerk_id: "clerk_attacker",
              invitation_email_status: "sent",
              role: "coach",
              invitation_status: "revoked",
              cohort_ids: [ cohort.id ]
            }
          },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    user.reload
    assert_equal "strong-params-user@example.com", user.email
    assert_not_equal "clerk_attacker", user.clerk_id
    assert_equal "not_sent", user.invitation_email_status
    assert_equal "coach", user.role
    assert_equal "revoked", user.invitation_status
  end

  test "invalid invitation status is rejected instead of persisted" do
    admin = create_user(email: "invalid-status-owner@example.com", role: "admin")
    user = create_user(email: "invalid-status-user@example.com", role: "participant")
    cohort = Cohort.create!(name: "Invalid Status Pilot", status: "draft", created_by_user: admin)
    user.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "participant", invitation_status: "super_revoked", cohort_ids: [ cohort.id ] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Invitation status is not valid"
    assert_equal "accepted", user.reload.invitation_status
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

  test "admin cannot save coach or participant users without cohorts" do
    admin = create_user(email: "require-cohort-owner@example.com", role: "admin")
    user = create_user(email: "require-cohort-user@example.com", role: "participant")
    cohort = Cohort.create!(name: "Required Pilot", status: "draft", created_by_user: admin)
    user.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "participant", cohort_ids: [] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Participant users must be assigned to at least one cohort"
    assert_equal [ cohort ], user.reload.cohorts.to_a
  end

  test "admin can revoke a pending participant and remove all cohort assignments" do
    admin = create_user(email: "cancel-owner@example.com", role: "admin")
    user = User.create!(
      clerk_id: "pending_#{SecureRandom.hex(6)}",
      email: "cancel-participant@example.com",
      role: "participant",
      invitation_status: "pending"
    )
    cohort = Cohort.create!(name: "Cancel Pilot", status: "draft", created_by_user: admin)
    user.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "participant", invitation_status: "revoked", cohort_ids: [] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    user.reload
    assert_equal "revoked", user.invitation_status
    assert_empty user.cohorts
  end

  test "admin can revoke an accepted participant and remove their last cohort" do
    admin = create_user(email: "remove-owner@example.com", role: "admin")
    user = create_user(email: "remove-participant@example.com", role: "participant")
    cohort = Cohort.create!(name: "Remove Pilot", status: "draft", created_by_user: admin)
    user.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{user.id}",
          params: { user: { role: "participant", invitation_status: "revoked", cohort_ids: [] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :success
    user.reload
    assert_equal "revoked", user.invitation_status
    assert_empty user.cohorts
  end

  test "admin users can be saved without cohorts" do
    primary_admin = create_user(email: "primary-admin@example.com", role: "admin")
    secondary_admin = create_user(email: "secondary-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Admin Optional Pilot", status: "draft", created_by_user: primary_admin)
    secondary_admin.cohort_memberships.create!(cohort: cohort, role: "admin")

    patch "/api/v1/admin/users/#{secondary_admin.id}",
          params: { user: { role: "admin", cohort_ids: [] } },
          headers: auth_headers(primary_admin),
          as: :json

    assert_response :success
    assert_empty secondary_admin.reload.cohorts
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

  test "admin cannot demote their own admin role" do
    admin = create_user(email: "self-demote-admin@example.com", role: "admin")
    cohort = Cohort.create!(name: "Self Demote Pilot", status: "draft", created_by_user: admin)

    patch "/api/v1/admin/users/#{admin.id}",
          params: { user: { role: "participant", cohort_ids: [ cohort.id ] } },
          headers: auth_headers(admin),
          as: :json

    assert_response :forbidden
    assert_equal "You cannot remove your own admin access", JSON.parse(response.body).fetch("error")
    assert_equal "admin", admin.reload.role
  end

  test "admin can update a revoked admin without tripping last-admin guard" do
    active_admin = create_user(email: "active-admin@example.com", role: "admin")
    revoked_admin = create_user(email: "revoked-admin@example.com", role: "admin")
    revoked_admin.update!(invitation_status: "revoked")
    cohort = Cohort.create!(name: "Former Admin Pilot", status: "draft", created_by_user: active_admin)

    patch "/api/v1/admin/users/#{revoked_admin.id}",
          params: { user: { first_name: "Former", role: "participant", cohort_ids: [ cohort.id ] } },
          headers: auth_headers(active_admin),
          as: :json

    assert_response :success
    revoked_admin.reload
    assert_equal "Former", revoked_admin.first_name
    assert_equal "participant", revoked_admin.role
    assert_equal "revoked", revoked_admin.invitation_status
    assert_equal [ cohort ], revoked_admin.cohorts.to_a
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

  test "coach cannot update participants outside assigned cohorts" do
    admin = create_user(email: "outside-admin@example.com", role: "admin")
    coach = create_user(email: "outside-coach@example.com", role: "coach")
    assigned_cohort = Cohort.create!(name: "Outside Assigned Pilot", status: "active", created_by_user: admin)
    other_cohort = Cohort.create!(name: "Outside Other Pilot", status: "active", created_by_user: admin)
    participant = create_user(email: "outside-participant@example.com", role: "participant")
    coach.cohort_memberships.create!(cohort: assigned_cohort, role: "coach")
    participant.cohort_memberships.create!(cohort: other_cohort, role: "participant")

    patch "/api/v1/admin/users/#{participant.id}",
          params: { user: { first_name: "Changed", role: "participant", cohort_ids: [ other_cohort.id ] } },
          headers: auth_headers(coach),
          as: :json

    assert_response :forbidden
    assert_equal "User update not permitted", JSON.parse(response.body).fetch("error")
    assert_nil participant.reload.first_name
  end

  test "coach cannot update participant invitation status through the API" do
    admin = create_user(email: "coach-status-admin@example.com", role: "admin")
    coach = create_user(email: "coach-status@example.com", role: "coach")
    participant = create_user(email: "coach-status-participant@example.com", role: "participant")
    cohort = Cohort.create!(name: "Coach Status Pilot", status: "active", created_by_user: admin)
    coach.cohort_memberships.create!(cohort: cohort, role: "coach")
    participant.cohort_memberships.create!(cohort: cohort, role: "participant")

    patch "/api/v1/admin/users/#{participant.id}",
          params: { user: { role: "participant", invitation_status: "revoked", cohort_ids: [ cohort.id ] } },
          headers: auth_headers(coach),
          as: :json

    assert_response :forbidden
    assert_equal "Status update not permitted", JSON.parse(response.body).fetch("error")
    assert_equal "accepted", participant.reload.invitation_status
  end

  test "admin users index returns only five recent invite attempts" do
    admin = create_user(email: "recent-attempt-admin@example.com", role: "admin")
    user = create_user(email: "recent-attempt-user@example.com", role: "participant")
    base_time = Time.zone.local(2026, 6, 23, 12, 0, 0)
    attempts = 7.times.map do |index|
      user.invitation_email_attempts.create!(
        status: "skipped",
        provider: "resend",
        error: "not configured #{index}",
        attempted_at: base_time + index.minutes,
        sent_by_user: admin
      )
    end

    get "/api/v1/admin/users", headers: auth_headers(admin)

    assert_response :success
    row = JSON.parse(response.body).fetch("users").find { |payload| payload.fetch("email") == user.email }
    delivery_log = row.fetch("invite_email").fetch("delivery_log")
    assert_equal attempts.last(5).map(&:id), delivery_log.map { |attempt| attempt.fetch("id") }
  end

  test "admin can resend pending invitations" do
    admin = create_user(email: "resend-admin@example.com", role: "admin")
    user = User.create!(
      clerk_id: "pending_#{SecureRandom.hex(6)}",
      email: "pending-resend@example.com",
      role: "participant",
      invitation_status: "pending"
    )

    post "/api/v1/admin/users/#{user.id}/resend_invitation", headers: auth_headers(admin)

    assert_response :success
    user.reload
    assert_equal "failed", user.invitation_email_status
    assert_equal 1, user.invitation_email_attempts.count
    assert_equal admin, user.invitation_email_attempts.last.sent_by_user
    assert_not_nil user.last_invite_email_attempted_at
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("invitation_sent")
    assert_equal "failed", body.fetch("invitation_status")
  end

  test "resending invitations preserves original inviter audit fields" do
    original_inviter = create_user(email: "original-inviter@example.com", role: "admin")
    resender = create_user(email: "resender@example.com", role: "admin")
    original_invited_at = 2.days.ago.change(usec: 0)
    user = User.create!(
      clerk_id: "pending_#{SecureRandom.hex(6)}",
      email: "pending-audit@example.com",
      role: "participant",
      invitation_status: "pending",
      invited_by_user: original_inviter,
      invited_at: original_invited_at
    )

    post "/api/v1/admin/users/#{user.id}/resend_invitation", headers: auth_headers(resender)

    assert_response :success
    user.reload
    assert_equal original_inviter, user.invited_by_user
    assert_equal original_invited_at.to_i, user.invited_at.to_i
    assert_equal resender, user.invitation_email_attempts.last.sent_by_user
  end

  test "accepted and revoked users cannot receive resend invitations" do
    admin = create_user(email: "resend-block-admin@example.com", role: "admin")
    accepted_user = create_user(email: "accepted-resend@example.com", role: "participant")
    revoked_user = User.create!(
      clerk_id: "pending_#{SecureRandom.hex(6)}",
      email: "revoked-resend@example.com",
      role: "participant",
      invitation_status: "revoked"
    )

    post "/api/v1/admin/users/#{accepted_user.id}/resend_invitation", headers: auth_headers(admin)
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Accepted users do not need another invitation"

    post "/api/v1/admin/users/#{revoked_user.id}/resend_invitation", headers: auth_headers(admin)
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Reactivate this user before resending an invitation"
  end

  test "admin user progress exposes operational pilot signals without household financial details" do
    admin = create_user(email: "progress-admin@example.com", role: "admin")
    participant = create_user(email: "progress-participant@example.com", role: "participant")
    participant.update!(invited_at: 2.days.ago, last_sign_in_at: 1.hour.ago)
    household = HouseholdFinance::WorkspaceResolver.new(participant).household
    household.household_audit_events.create!(
      user: participant,
      actor_type: "user",
      event_type: "workspace.setup_saved",
      metadata: { setup_complete: false },
      occurred_at: 30.minutes.ago
    )

    get "/api/v1/admin/users", headers: auth_headers(admin)

    assert_response :success
    row = JSON.parse(response.body).fetch("users").find { |user| user.fetch("id") == participant.id }
    progress = row.fetch("workspace")
    assert_equal true, progress.fetch("invited")
    assert_equal true, progress.fetch("signed_in")
    assert_equal "started", progress.fetch("setup_status")
    assert_equal false, progress.fetch("setup_complete")
    assert_equal false, progress.fetch("has_pending_review_work")
    assert progress.fetch("last_safe_activity_at").present?
    assert_equal %w[has_pending_review_work invited last_safe_activity_at setup_complete setup_status signed_in], progress.keys.sort
    assert_not_includes response.body, household.name
    assert_not_includes response.body, "profile_completeness"
    assert_not_includes response.body, "readiness_label"
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

  def with_user_invite_email_stub(result)
    original_method = UserInviteEmailService.method(:send_invite)
    UserInviteEmailService.define_singleton_method(:send_invite) { |user:, invited_by:| result }
    yield
  ensure
    UserInviteEmailService.define_singleton_method(:send_invite, original_method)
  end
end
