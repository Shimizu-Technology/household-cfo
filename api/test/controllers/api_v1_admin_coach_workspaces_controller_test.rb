# frozen_string_literal: true

require "test_helper"

class ApiV1AdminCoachWorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "first platform admin creates a complete workspace without choosing one" do
    admin = user("admin")
    assert_difference "CoachWorkspace.count", 1 do
      post "/api/v1/admin/coach_workspaces", params: settings("Island Money"), headers: headers(admin), as: :json
      assert_response :created
    end
    record = CoachWorkspace.find(response.parsed_body.dig("coach_workspace", "id"))
    assert_equal "owner", record.membership_for(admin).role
    assert_equal Digest::SHA256.hexdigest(JSON.generate([ "Island Money", { display_name: "Mrs. Mel", title: "Financial coach", bio: "Clear next steps." }.sort.to_h, "" ])), record.creation_request_fingerprint
    assert_equal "Mrs. Mel", record.coach_profile.display_name
    assert record.workspace_brand_configuration.current_published_version
    assert_equal true, response.parsed_body.dig("coach_workspace", "permissions", "manage")
  end

  test "program owner invitation can skip email and the preference is part of the retry contract" do
    admin = user("admin")
    request_headers = headers(admin).merge("Idempotency-Key" => SecureRandom.uuid)
    payload = with_owner(settings("No email program"), "no-email-owner@example.test")
    payload[:coach_workspace][:send_invitation_email] = false
    post "/api/v1/admin/coach_workspaces", params: payload, headers: request_headers, as: :json
    assert_response :created
    owner = User.find_by!(email: "no-email-owner@example.test")
    record = CoachWorkspace.find(response.parsed_body.dig("coach_workspace", "id"))
    assert_equal "owner", record.membership_for(owner).role
    assert_equal "pending", owner.invitation_status
    assert_equal "skipped", response.parsed_body.dig("owner_invitation", "delivery", "status")
    assert_equal "skipped", owner.invitation_email_attempts.last.status
    assert_no_difference "CoachWorkspace.count" do
      post "/api/v1/admin/coach_workspaces", params: payload, headers: request_headers, as: :json
      assert_response :success
    end
    payload[:coach_workspace][:send_invitation_email] = true
    post "/api/v1/admin/coach_workspaces", params: payload, headers: request_headers, as: :json
    assert_response :conflict
  end

  test "workspace creation replays without duplication and rejects changed input" do
    admin = user("admin")
    key = SecureRandom.uuid
    request_headers = headers(admin).merge("Idempotency-Key" => key)
    post "/api/v1/admin/coach_workspaces", params: settings("Island program"), headers: request_headers, as: :json
    assert_response :created
    created_id = response.parsed_body.dig("coach_workspace", "id")
    assert_no_difference "CoachWorkspace.count" do
      post "/api/v1/admin/coach_workspaces", params: settings("Island program"), headers: request_headers, as: :json
      assert_response :success
      assert_equal created_id, response.parsed_body.dig("coach_workspace", "id")
    end
    post "/api/v1/admin/coach_workspaces", params: settings("Different program"), headers: request_headers, as: :json
    assert_response :conflict
  end

  test "workspace owners can save identity and profile atomically and stale edits cannot overwrite" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    revision = workspace.lock_version
    patch endpoint(workspace), params: settings("New program", revision: revision), headers: headers(owner), as: :json
    assert_response :success
    assert_equal "New program", workspace.reload.name
    assert_equal "Mrs. Mel", workspace.coach_profile.reload.display_name
    assert_operator workspace.lock_version, :>, revision
    patch endpoint(workspace), params: settings("Stale name", revision: revision), headers: headers(owner), as: :json
    assert_response :conflict
    assert_equal "New program", workspace.reload.name
    assert_equal "Mrs. Mel", workspace.coach_profile.reload.display_name
  end

  test "invalid profile rolls back workspace rename" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    original_name = workspace.name
    payload = settings("Should roll back", revision: workspace.lock_version)
    payload[:coach_workspace][:coach_profile][:display_name] = ""
    patch endpoint(workspace), params: payload, headers: headers(owner), as: :json
    assert_response :unprocessable_entity
    assert_equal original_name, workspace.reload.name
  end

  test "editor reviewer and viewer can view but cannot change workspace identity" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    %w[editor reviewer viewer].each do |role|
      collaborator = user("coach")
      workspace.coach_workspace_memberships.create!(user: collaborator, role: role)
      get endpoint(workspace), headers: headers(collaborator)
      assert_response :success
      assert_equal false, response.parsed_body.dig("coach_workspace", "permissions", "manage")
      patch endpoint(workspace), params: settings("Denied", revision: workspace.lock_version), headers: headers(collaborator), as: :json
      assert_response :not_found
    end
  end

  test "outsiders and participants cannot read or change settings and coaches cannot provision programs" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    outsider = user("coach")
    get endpoint(workspace), headers: headers(outsider)
    assert_response :not_found
    post "/api/v1/admin/coach_workspaces", params: settings("Denied"), headers: headers(outsider), as: :json
    assert_response :forbidden
    get endpoint(workspace), headers: headers(user("participant"))
    assert_response :forbidden
  end

  test "owner demotion between settings authorization and lock denies the whole save" do
    owner = user("coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    original_name = workspace.name
    original = CoachWorkspace.instance_method(:with_lock)
    demoted = false
    CoachWorkspace.define_method(:with_lock) do |*args, &block|
      unless demoted || id != workspace.id
        demoted = true
        CoachWorkspaceMembership.find_by!(coach_workspace_id: id, user_id: owner.id).update!(role: "viewer")
      end
      original.bind_call(self, *args, &block)
    end
    patch endpoint(workspace), params: settings("Unauthorized change", revision: workspace.lock_version), headers: headers(owner), as: :json
    assert_response :not_found
    assert_equal original_name, workspace.reload.name
    assert_equal "your coach", workspace.coach_profile.reload.display_name
  ensure
    CoachWorkspace.define_method(:with_lock, original) if original
  end

  test "admin revocation while settings save waits denies rename and profile changes" do
    admin = user("admin")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(admin)
    original_name = workspace.name
    original = CoachWorkspace.instance_method(:with_lock)
    revoked = false
    CoachWorkspace.define_method(:with_lock) do |*args, &block|
      unless revoked || id != workspace.id
        revoked = true
        User.find(admin.id).update!(invitation_status: "revoked")
      end
      original.bind_call(self, *args, &block)
    end
    patch endpoint(workspace), params: settings("Unauthorized admin rename", revision: workspace.lock_version), headers: headers(admin), as: :json
    assert_response :not_found
    assert_equal original_name, workspace.reload.name
    assert_equal "your coach", workspace.coach_profile.reload.display_name
  ensure
    CoachWorkspace.define_method(:with_lock, original) if original
  end

  test "admin revocation after initial creation check denies creating a program" do
    admin = user("admin")
    controller = Api::V1::Admin::CoachWorkspacesController
    original = controller.instance_method(:require_admin!)
    controller.define_method(:require_admin!) do
      original.bind_call(self)
      User.find(current_user.id).update!(invitation_status: "revoked")
    end
    assert_no_difference [ "CoachWorkspace.count", "CoachProfile.count", "WorkspaceBrandVersion.count" ] do
      post "/api/v1/admin/coach_workspaces", params: settings("Denied creation"), headers: headers(admin), as: :json
      assert_response :not_found
    end
  ensure
    controller&.send(:remove_method, :require_admin!)
  end

  test "admin can name an existing coach as owner and keeps platform authority" do
    admin = user("admin")
    coach = user("coach")
    post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Mel program"), coach.email.upcase), headers: headers(admin), as: :json
    assert_response :created
    record = CoachWorkspace.find(response.parsed_body.dig("coach_workspace", "id"))
    assert_equal "owner", record.membership_for(coach).role
    assert_nil record.membership_for(admin)
    assert_nil response.parsed_body["owner_invitation"]

    get endpoint(record), headers: headers(admin)
    assert_response :success
    assert_equal true, response.parsed_body.dig("coach_workspace", "permissions", "manage")
    get endpoint(record), headers: headers(coach)
    assert_equal true, response.parsed_body.dig("coach_workspace", "permissions", "manage")
  end

  test "naming an unknown email invites a pending coach as owner" do
    admin = user("admin")
    assert_difference "User.count", 1 do
      post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Invite program"), " New.Coach@Example.test "), headers: headers(admin), as: :json
    end
    assert_response :created
    invited = User.find_by!("LOWER(email) = ?", "new.coach@example.test")
    assert_equal "coach", invited.role
    assert_equal "pending", invited.invitation_status
    record = CoachWorkspace.find(response.parsed_body.dig("coach_workspace", "id"))
    assert_equal "owner", record.membership_for(invited).role
    assert_equal "new.coach@example.test", response.parsed_body.dig("owner_invitation", "email")
  end

  test "owner that cannot own a program is a plain error and creates nothing" do
    admin = user("admin")
    participant = user("participant")
    revoked = user("coach")
    revoked.update!(invitation_status: "revoked")
    [ participant.email, revoked.email, "not-an-email" ].each do |email|
      assert_no_difference [ "CoachWorkspace.count", "User.count" ] do
        post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Bad owner"), email), headers: headers(admin), as: :json
      end
      assert_response :unprocessable_entity
      assert_equal "coach_workspace_owner_invalid", response.parsed_body["code"]
    end
  end

  test "owner email is part of the creation fingerprint" do
    admin = user("admin")
    coach = user("coach")
    request_headers = headers(admin).merge("Idempotency-Key" => SecureRandom.uuid)
    post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Same"), coach.email), headers: request_headers, as: :json
    assert_response :created
    id = response.parsed_body.dig("coach_workspace", "id")
    post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Same"), coach.email.upcase), headers: request_headers, as: :json
    assert_response :success
    assert_equal id, response.parsed_body.dig("coach_workspace", "id")
    post "/api/v1/admin/coach_workspaces", params: settings("Same"), headers: request_headers, as: :json
    assert_response :conflict
    post "/api/v1/admin/coach_workspaces", params: with_owner(settings("Same"), user("coach").email), headers: request_headers, as: :json
    assert_response :conflict
  end

  test "owner_email is ignored on update" do
    admin = user("admin")
    coach = user("coach")
    post "/api/v1/admin/coach_workspaces", params: settings("Keep owner"), headers: headers(admin), as: :json
    record = CoachWorkspace.find(response.parsed_body.dig("coach_workspace", "id"))
    payload = with_owner(settings("Keep owner", revision: record.lock_version), coach.email)
    patch endpoint(record), params: payload, headers: headers(admin), as: :json
    assert_response :success
    assert_nil record.reload.membership_for(coach)
  end

  test "a platform admin who owns no program defaults to an existing one instead of provisioning" do
    owner = user("coach")
    existing = CoachWorkspaces::Provisioner.ensure_for!(owner)
    admin = user("admin")
    assert_no_difference "CoachWorkspace.count" do
      assert_equal existing, CoachWorkspaces::Resolver.new(user: admin).call
    end
    assert_nil existing.membership_for(admin)
  end

  private

  def with_owner(payload, email)
    payload[:coach_workspace][:owner_email] = email
    payload
  end

  def user(role)
    User.create!(clerk_id: "settings-#{SecureRandom.uuid}", email: "#{SecureRandom.hex(6)}@example.test", role: role)
  end

  def headers(account)
    { "Authorization" => "Bearer test_token_#{account.id}" }
  end

  def endpoint(workspace)
    "/api/v1/admin/coach_workspaces/#{workspace.id}"
  end

  def settings(name, revision: nil)
    { coach_workspace: { name: name, revision: revision, coach_profile: { display_name: "Mrs. Mel", title: "Financial coach", bio: "Clear next steps." } } }
  end
end
