require "test_helper"

class ApiV1WorkspaceCollaboratorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = user
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @endpoint = "/api/v1/admin/collaborators"
  end

  test "only owners and platform admins can list or manage the selected workspace" do
    %w[editor reviewer viewer].each do |role|
      coach = user
      @workspace.coach_workspace_memberships.create!(user: coach, role: role)
      get @endpoint, headers: headers(coach)
      assert_response :not_found
      post @endpoint, params: { collaborator: { email: "blocked@example.test", role: "owner" } }, headers: headers(coach), as: :json
      assert_response :not_found
    end
    outsider = user
    get @endpoint, headers: headers(outsider)
    assert_response :not_found
    participant = user(role: "participant")
    get @endpoint, headers: headers(participant)
    assert_response :forbidden
    get @endpoint, headers: headers(@owner)
    assert_response :success
    assert_equal @workspace.id, response.parsed_body["workspace_id"]
    admin = user(role: "admin")
    get @endpoint, headers: headers(admin)
    assert_response :success
  end

  test "new collaborator invitation saves access and truthfully reports skipped or unavailable delivery" do
    post @endpoint, params: { collaborator: { email: "New.Coach@example.test", role: "editor", send_email: false } }, headers: headers(@owner), as: :json
    assert_response :created
    payload = response.parsed_body
    assert_equal "skipped", payload.dig("delivery", "status")
    invited = User.find_by!(email: "new.coach@example.test")
    assert invited.invitation_pending?
    assert_equal "coach", invited.role
    assert_equal "editor", @workspace.coach_workspace_memberships.find_by!(user: invited).role
    assert_equal "added", CoachWorkspaceMembershipEvent.last.event_type
    assert_equal "skipped", invited.invitation_email_attempts.last.status

    provider_environment = %w[RESEND_API_KEY RESEND_FROM_EMAIL MAILER_FROM_EMAIL].to_h { |key| [ key, ENV[key] ] }
    provider_environment.each_key { |key| ENV.delete(key) }
    original_send = Resend::Emails.method(:send)
    provider_called = false
    Resend::Emails.define_singleton_method(:send) do |_payload|
      provider_called = true
      raise "Unavailable email delivery must not contact Resend"
    end
    post @endpoint, params: { collaborator: { email: "another@example.test", role: "viewer", send_email: true } }, headers: headers(@owner), as: :json
    assert_response :created
    assert_equal "failed", response.parsed_body.dig("delivery", "status")
    refute provider_called, "Unavailable email delivery contacted Resend"
    assert @workspace.coach_workspace_memberships.joins(:user).exists?(users: { email: "another@example.test" })
  ensure
    Resend::Emails.define_singleton_method(:send, original_send) if original_send
    provider_environment&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "adding an existing coach preserves global identity and other workspace permissions" do
    coach = user
    other = CoachWorkspaces::Provisioner.ensure_for!(coach)
    post @endpoint, params: { collaborator: { email: coach.email, role: "reviewer", send_email: false } }, headers: headers(@owner), as: :json
    assert_response :created
    assert_equal false, response.parsed_body["new_user"]
    assert_equal "coach", coach.reload.role
    assert coach.invitation_accepted?
    assert_equal "owner", other.coach_workspace_memberships.find_by!(user: coach).role
    member = @workspace.coach_workspace_memberships.find_by!(user: coach)
    assert_equal "reviewer", member.role
    assert_no_difference "CoachWorkspaceMembershipEvent.count" do
      post @endpoint, params: { collaborator: { email: coach.email, role: "reviewer", send_email: true } }, headers: headers(@owner), as: :json
    end
    assert_response :success
    assert_equal false, response.parsed_body["added"]
    assert_nil response.parsed_body["delivery"]
  end

  test "legacy mixed case email reuses the locked coach account without changing identity" do
    coach = user
    other = CoachWorkspaces::Provisioner.ensure_for!(coach)
    legacy_email = "Legacy.Coach-#{SecureRandom.hex(5)}@Example.test"
    connection = ActiveRecord::Base.connection
    connection.execute("UPDATE users SET email = #{connection.quote(legacy_email)} WHERE id = #{coach.id}")
    assert_no_difference "User.count" do
      post @endpoint, params: { collaborator: { email: legacy_email.downcase, role: "reviewer", send_email: false } }, headers: headers(@owner), as: :json
    end
    assert_response :created
    assert_equal false, response.parsed_body["new_user"]
    assert_equal legacy_email, coach.reload.email
    assert_equal "reviewer", @workspace.coach_workspace_memberships.find_by!(user: coach).role
    assert_equal "owner", other.coach_workspace_memberships.find_by!(user: coach).role
  end

  test "collaborator invite never upgrades participants or reactivates a revoked account" do
    [ user(role: "participant"), user(status: "revoked") ].each do |account|
      post @endpoint, params: { collaborator: { email: account.email, role: "owner", send_email: false } }, headers: headers(@owner), as: :json
      assert_response :unprocessable_entity
      assert_nil @workspace.coach_workspace_memberships.find_by(user: account)
    end
  end

  test "self demotion self removal and last active owner are protected including pending replacements" do
    member = @workspace.coach_workspace_memberships.find_by!(user: @owner)
    patch "#{@endpoint}/#{member.id}", params: { collaborator: { role: "viewer", expected_role: "owner" } }, headers: headers(@owner), as: :json
    assert_response :unprocessable_entity
    delete "#{@endpoint}/#{member.id}", params: { collaborator: { expected_role: "owner" } }, headers: headers(@owner), as: :json
    assert_response :unprocessable_entity
    pending = user(status: "pending")
    pending.update!(clerk_id: "pending_#{SecureRandom.hex(4)}")
    @workspace.coach_workspace_memberships.create!(user: pending, role: "owner")
    admin = user(role: "admin")
    delete "#{@endpoint}/#{member.id}", params: { collaborator: { expected_role: "owner" } }, headers: headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "owner", member.reload.role
    replacement = user
    @workspace.coach_workspace_memberships.create!(user: replacement, role: "owner")
    delete "#{@endpoint}/#{member.id}", params: { collaborator: { expected_role: "owner" } }, headers: headers(admin), as: :json
    assert_response :success
    assert_nil @workspace.coach_workspace_memberships.find_by(user: @owner)
  end

  test "role changes preserve audit attribution and reject stale roles and cross workspace ids" do
    coach = user
    member = @workspace.coach_workspace_memberships.create!(user: coach, role: "editor")
    patch "#{@endpoint}/#{member.id}", params: { collaborator: { role: "reviewer", expected_role: "editor" } }, headers: headers(@owner), as: :json
    assert_response :success
    event = CoachWorkspaceMembershipEvent.last
    assert_equal [ @owner.id, coach.id, "editor", "reviewer" ], [ event.actor_user_id, event.subject_user_id, event.before_role, event.after_role ]
    patch "#{@endpoint}/#{member.id}", params: { collaborator: { role: "viewer", expected_role: "editor" } }, headers: headers(@owner), as: :json
    assert_response :conflict
    assert_equal "reviewer", member.reload.role
    other = CoachWorkspaces::Provisioner.ensure_for!(user)
    outside = other.coach_workspace_memberships.first
    patch "#{@endpoint}/#{outside.id}", params: { collaborator: { role: "viewer", expected_role: outside.role } }, headers: headers(@owner), as: :json
    assert_response :not_found
    refute event.update(after_role: "owner")
    refute event.destroy
  end

  test "removal ends coached staff access without removing participant or other program enrollment" do
    coach = user
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(coach)
    local_staff = Cohort.create!(name: "Local staff", created_by_user: @owner, coach_workspace: @workspace)
    local_participant = Cohort.create!(name: "Local participant", created_by_user: @owner, coach_workspace: @workspace)
    other_staff = Cohort.create!(name: "Other staff", created_by_user: coach, coach_workspace: other_workspace)
    local_staff.cohort_memberships.create!(user: coach, role: "coach")
    participant_membership = local_participant.cohort_memberships.create!(user: coach, role: "participant")
    other_membership = other_staff.cohort_memberships.create!(user: coach, role: "coach")
    member = @workspace.coach_workspace_memberships.find_by!(user: coach)
    delete "#{@endpoint}/#{member.id}", params: { collaborator: { expected_role: "editor" } }, headers: headers(@owner), as: :json
    assert_response :success
    assert_nil @workspace.coach_workspace_memberships.find_by(user: coach)
    assert_empty local_staff.cohort_memberships.where(user: coach)
    assert CohortMembership.exists?(participant_membership.id)
    assert CohortMembership.exists?(other_membership.id)
    CohortMembership.reconcile_workspace_access!(@workspace, coach)
    assert_nil @workspace.coach_workspace_memberships.find_by(user: coach)
    assert coach.reload.invitation_accepted?
  end

  test "claiming a cohort managed collaborator as the same explicit role prevents later automatic removal" do
    coach = user
    cohort = Cohort.create!(name: "Managed access", created_by_user: @owner, coach_workspace: @workspace)
    assignment = cohort.cohort_memberships.create!(user: coach, role: "coach")
    member = @workspace.coach_workspace_memberships.find_by!(user: coach)
    assert member.cohort_managed?
    post @endpoint, params: { collaborator: { email: coach.email, role: "editor", send_email: false } }, headers: headers(@owner), as: :json
    assert_response :success
    refute member.reload.cohort_managed?
    assignment.destroy!
    assert CoachWorkspaceMembership.exists?(member.id)
  end

  test "platform account revocation and demotion require handover in every owned workspace" do
    admin = user(role: "admin")
    cohort = Cohort.create!(name: "Owner assignment", created_by_user: @owner, coach_workspace: @workspace)
    cohort.cohort_memberships.create!(user: @owner, role: "coach")
    platform_headers = { "Authorization" => "Bearer test_token_#{admin.id}" }
    patch "/api/v1/admin/users/#{@owner.id}", params: { user: { invitation_status: "revoked" } }, headers: platform_headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "workspace_owner_handover_required", response.parsed_body["code"]
    assert @owner.reload.invitation_accepted?
    patch "/api/v1/admin/users/#{@owner.id}", params: { user: { role: "participant", cohort_ids: [ cohort.id ] } }, headers: platform_headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "coach", @owner.reload.role

    replacement = user
    @workspace.coach_workspace_memberships.create!(user: replacement, role: "owner")
    second_workspace = CoachWorkspace.create!(name: "Second owned workspace", slug: "second-#{SecureRandom.hex(4)}", created_by_user: @owner)
    second_workspace.coach_workspace_memberships.create!(user: @owner, role: "owner")
    patch "/api/v1/admin/users/#{@owner.id}", params: { user: { invitation_status: "revoked" } }, headers: platform_headers, as: :json
    assert_response :unprocessable_entity
    second_workspace.coach_workspace_memberships.create!(user: replacement, role: "owner")
    patch "/api/v1/admin/users/#{@owner.id}", params: { user: { role: "participant", cohort_ids: [ cohort.id ] } }, headers: platform_headers, as: :json
    assert_response :success
    assert_equal "participant", @owner.reload.role
    assert_empty @owner.coach_workspace_memberships
    assert_equal "participant", cohort.cohort_memberships.find_by!(user: @owner).role
    assert_equal 2, CoachWorkspaceMembershipEvent.where(subject_user: @owner, event_type: "removed", actor_user: admin).count
  end

  private

  def user(role: "coach", status: "accepted")
    User.create!(email: "collaborator-#{SecureRandom.hex(6)}@example.test", clerk_id: "clerk_#{SecureRandom.hex(6)}", role: role, invitation_status: status)
  end

  def headers(account)
    { "Authorization" => "Bearer test_token_#{account.id}", "X-Coach-Workspace-Id" => @workspace.id.to_s }
  end
end
