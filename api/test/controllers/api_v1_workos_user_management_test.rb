require "test_helper"

class ApiV1WorkosUserManagementTest < ActionDispatch::IntegrationTest
  test "editing a bound WorkOS administrator preserves accepted state and compatibility identity" do
    actor = clerk_admin
    target = workos_user(role: "admin")
    patch "/api/v1/admin/users/#{target.id}", params: { user: { first_name: "Updated", invitation_status: "pending" } },
      headers: headers(actor), as: :json
    assert_response :success
    assert_equal "accepted", target.reload.invitation_status
    assert_equal "Updated", target.first_name
    assert target.clerk_id.start_with?("pending_")
    assert target.invitation_accepted?
  end

  test "account revocation accepts another bound WorkOS owner and refuses the final owner" do
    actor = clerk_admin
    first = workos_user(role: "coach")
    second = workos_user(role: "coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(first)
    workspace.coach_workspace_memberships.create!(user: second, role: "owner")
    patch "/api/v1/admin/users/#{first.id}", params: { user: { invitation_status: "revoked" } }, headers: headers(actor), as: :json
    assert_response :success
    assert first.reload.revoked?
    patch "/api/v1/admin/users/#{second.id}", params: { user: { invitation_status: "revoked" } }, headers: headers(actor), as: :json
    assert_response :unprocessable_entity
    assert_equal "workspace_owner_handover_required", response.parsed_body.fetch("code")
    assert second.reload.invitation_accepted?
  end

  test "an unbound accepted placeholder never becomes accepted through an admin status edit" do
    actor = clerk_admin
    target = User.create!(email: "unbound@example.test", clerk_id: "workos_user_unbound", role: "admin", invitation_status: "accepted")
    patch "/api/v1/admin/users/#{target.id}", params: { user: { first_name: "Unbound" } }, headers: headers(actor), as: :json
    assert_response :success
    assert_equal "pending", target.reload.invitation_status
    refute target.invitation_accepted?
  end

  private

  def clerk_admin
    User.create!(email: "platform@example.test", clerk_id: "clerk_platform", role: "admin")
  end

  def workos_user(role:)
    id = SecureRandom.hex(8)
    user = User.create!(email: "#{id}@example.test", clerk_id: "pending_#{id}", role: role, invitation_status: "accepted")
    user.authentication_identities.create!(provider: "workos", issuer: "https://api.workos.com", subject: "user_#{id}")
    user
  end

  def headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
