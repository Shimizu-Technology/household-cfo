require "test_helper"

class ApiV1CoachGroupsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = user("groups-owner", "coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @cohort = Cohort.create!(name: "Owner's group", status: "enrolling", created_by_user: @owner, coach_workspace: @workspace)
    @participant = user("groups-participant", "participant")
    @membership = @cohort.cohort_memberships.create!(user: @participant, role: "participant")
  end

  test "owner explicitly selects workspace and creates lists and updates scoped groups" do
    get "/api/v1/admin/cohorts", headers: auth(@owner)
    assert_response :unprocessable_entity
    post "/api/v1/admin/cohorts", params: { cohort: { name: "Second group", status: "enrolling" } }, headers: auth(@owner, @workspace), as: :json
    assert_response :created
    created = Cohort.find(response.parsed_body.dig("cohort", "id"))
    assert_equal @workspace.id, created.coach_workspace_id
    get "/api/v1/admin/cohorts", headers: auth(@owner, @workspace)
    assert_response :success
    row = response.parsed_body.fetch("cohorts").find { |item| item.fetch("id") == @cohort.id }
    patch "/api/v1/admin/cohorts/#{@cohort.id}", params: { cohort: { name: "Renamed group", status: "active", expected_updated_at: row.fetch("updated_at") } }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert_equal "Renamed group", @cohort.reload.name
    assert_equal "active", @cohort.status
    assert_nil @cohort.active_cohort_release_id, "Changing status must not implicitly launch a release"
    patch "/api/v1/admin/cohorts/#{@cohort.id}", params: { cohort: { name: "Stale overwrite", expected_updated_at: row.fetch("updated_at") } }, headers: auth(@owner, @workspace), as: :json
    assert_response :conflict
    assert_equal "Renamed group", @cohort.reload.name
  end

  test "explicit nonowner collaborators cannot read modify create or remove roster groups" do
    %w[editor reviewer viewer].each do |role|
      collaborator = user("group-#{role}", "coach")
      @workspace.coach_workspace_memberships.create!(user: collaborator, role: role)
      @cohort.cohort_memberships.create!(user: collaborator, role: "coach")
      get "/api/v1/admin/cohorts", headers: auth(collaborator, @workspace)
      assert_response :forbidden
      refute_includes response.body, @participant.email
      get "/api/v1/admin/cohorts/#{@cohort.id}", headers: auth(collaborator, @workspace)
      assert_response :forbidden
      assert_no_difference -> { Cohort.count } do
        post "/api/v1/admin/cohorts", params: { cohort: { name: "Denied #{role}", status: "active" } }, headers: auth(collaborator, @workspace), as: :json
      end
      assert_response :forbidden
      patch "/api/v1/admin/cohorts/#{@cohort.id}", params: { cohort: { status: "archived" } }, headers: auth(collaborator, @workspace), as: :json
      assert_response :forbidden
      delete enrollment_url, params: { expected_membership_id: @membership.id }, headers: auth(collaborator, @workspace), as: :json
      assert_response :forbidden
      assert @membership.reload.persisted?
    end
  end

  test "owner cannot target another workspace even with a valid participant ID" do
    other_owner = user("other-group-owner", "coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    other = Cohort.create!(name: "Other group's secret", status: "active", created_by_user: other_owner, coach_workspace: other_workspace)
    get "/api/v1/admin/cohorts/#{other.id}", headers: auth(@owner, @workspace)
    assert_response :not_found
    delete "/api/v1/admin/cohorts/#{other.id}/participants/#{@participant.id}", headers: auth(@owner, @workspace), as: :json
    assert_response :not_found
    get "/api/v1/admin/cohorts", headers: auth(@owner, @workspace)
    refute_includes response.body, other.name
  end

  test "local cancellation removes even the last enrollment without revoking global account" do
    delete enrollment_url, params: { expected_membership_id: @membership.id }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert response.parsed_body.fetch("removed")
    assert_empty @participant.cohort_memberships.reload
    assert_equal "accepted", @participant.reload.invitation_status
    delete enrollment_url, params: { expected_membership_id: @membership.id }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    refute response.parsed_body.fetch("removed")
    post "/api/v1/admin/users", params: { user: { email: @participant.email, role: "participant", cohort_id: @cohort.id } }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert_equal "skipped", response.parsed_body.fetch("invitation_status")
    assert_equal "accepted", @participant.reload.invitation_status
    assert @participant.cohort_memberships.exists?(cohort: @cohort)
  end

  test "stale cancellation cannot remove a newly replaced enrollment or staff access" do
    old_id = @membership.id
    @membership.destroy!
    replacement = @cohort.cohort_memberships.create!(user: @participant, role: "participant")
    delete enrollment_url, params: { expected_membership_id: old_id }, headers: auth(@owner, @workspace), as: :json
    assert_response :conflict
    assert replacement.reload.persisted?
    delete "/api/v1/admin/cohorts/#{@cohort.id}/participants/#{@owner.id}", headers: auth(@owner, @workspace), as: :json
    assert_response :success
    refute response.parsed_body.fetch("removed")
    assert_equal "owner", @workspace.membership_for(@owner).role
    delete "/api/v1/admin/cohorts/#{@cohort.id}/participants/999999999", params: { expected_membership_id: old_id }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    refute response.parsed_body.fetch("removed")
  end

  test "owner cannot enroll an outside-only participant by guessing their exact email" do
    other_owner = user("attach-other-owner", "coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    other = Cohort.create!(name: "Private other group", status: "active", created_by_user: other_owner, coach_workspace: other_workspace)
    shared = user("attach-shared", "participant")
    shared.update!(first_name: "Original", invitation_email_status: "failed", invitation_email_error: "Private error")
    shared.cohort_memberships.create!(cohort: other, role: "participant")
    assert_no_difference [ "CohortMembership.count", "InvitationEmailAttempt.count" ] do
      post "/api/v1/admin/users", params: { user: { email: shared.email, role: "participant", cohort_id: @cohort.id, send_invitation_email: true } }, headers: auth(@owner, @workspace), as: :json
    end
    assert_response :forbidden
    assert_nil response.parsed_body["user"]
    refute_includes response.body, other.name
    refute_includes response.body, "Private error"
    refute_includes response.body, "progress"
    assert_equal [ other.id ], shared.cohort_memberships.pluck(:cohort_id)
    assert_equal "Original", shared.reload.first_name
    assert_equal "accepted", shared.invitation_status
  end

  test "owner can add an already visible shared participant to another group without changing their account" do
    other_owner = user("attach-other-owner", "coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    other = Cohort.create!(name: "Private other group", status: "active", created_by_user: other_owner, coach_workspace: other_workspace)
    shared = user("attach-shared", "participant")
    shared.update!(first_name: "Original", invitation_email_status: "failed", invitation_email_error: "Private error")
    shared.cohort_memberships.create!(cohort: other, role: "participant")
    local = Cohort.create!(name: "Existing local group", status: "active", created_by_user: @owner, coach_workspace: @workspace)
    shared.cohort_memberships.create!(cohort: local, role: "participant")
    assert_no_difference -> { shared.invitation_email_attempts.count } do
      post "/api/v1/admin/users", params: { user: { email: shared.email, role: "participant", cohort_id: @cohort.id, send_invitation_email: true } }, headers: auth(@owner, @workspace), as: :json
    end
    assert_response :success
    refute response.parsed_body.fetch("invitation_sent")
    assert_equal "skipped", response.parsed_body.fetch("invitation_status")
    assert_equal [ @cohort.id, local.id ].sort, response.parsed_body.dig("user", "cohorts").map { |item| item.dig("cohort", "id") }.sort
    refute_includes response.body, other.name
    refute_includes response.body, "Private error"
    refute response.parsed_body.dig("user", "can_resend_invitation")
    assert_equal [ @cohort.id, local.id, other.id ].sort, shared.cohort_memberships.pluck(:cohort_id).sort
    assert_equal "Original", shared.reload.first_name
    assert_equal "accepted", shared.invitation_status
    delete "/api/v1/admin/cohorts/#{@cohort.id}/participants/#{shared.id}", params: { expected_membership_id: shared.cohort_memberships.find_by!(cohort: @cohort).id }, headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert_equal [ local.id, other.id ].sort, shared.cohort_memberships.pluck(:cohort_id).sort
  end

  test "owner cannot attach revoked staff or overwrite existing global names" do
    [ [ "revoked", "participant", {} ], [ "accepted", "coach", {} ], [ "accepted", "participant", { first_name: "Overwrite" } ] ].each_with_index do |(status, role, attributes), index|
      existing = user("guard-account-#{index}", role)
      existing.update!(invitation_status: status)
      existing.cohort_memberships.create!(cohort: @cohort, role: "participant") if status == "revoked"
      assert_no_difference -> { @cohort.cohort_memberships.count } do
        post "/api/v1/admin/users", params: { user: { email: existing.email, role: "participant", cohort_id: @cohort.id }.merge(attributes) }, headers: auth(@owner, @workspace), as: :json
      end
      assert_response :forbidden
      assert_equal role, existing.reload.role
      assert_equal status, existing.invitation_status
      assert_nil existing.first_name
    end
  end

  %w[create update remove].each do |action|
    test "owner demotion after initial authority check cannot #{action} group data" do
      with_late_authority_change do
        @workspace.membership_for(@owner).update!(role: "editor")
      end
      original_name = @cohort.name
      original_count = Cohort.count
      submit_group_action(action, @owner)
      assert_response :not_found
      assert_equal original_count, Cohort.count
      assert_equal original_name, @cohort.reload.name
      assert @membership.reload.persisted?
    end

    test "admin revocation after initial authority check cannot #{action} group data" do
      admin = user("group-revoked-admin-#{action}", "admin")
      with_late_authority_change { User.find(admin.id).update!(invitation_status: "revoked") }
      original_name = @cohort.name
      original_count = Cohort.count
      submit_group_action(action, admin)
      assert_response :not_found
      assert_equal original_count, Cohort.count
      assert_equal original_name, @cohort.reload.name
      assert @membership.reload.persisted?
    end
  end

  teardown do
    if @original_group_management
      Api::V1::Admin::CohortsController.define_method(:require_group_management!, @original_group_management)
      Api::V1::Admin::CohortsController.send(:private, :require_group_management!)
    end
  end

  private

  def with_late_authority_change(&change)
    controller = Api::V1::Admin::CohortsController
    @original_group_management = controller.instance_method(:require_group_management!)
    original = @original_group_management
    controller.define_method(:require_group_management!) do
      original.bind_call(self)
      change.call unless performed?
    end
  end

  def submit_group_action(action, actor)
    case action
    when "create"
      post "/api/v1/admin/cohorts", params: { cohort: { name: "Unauthorized group", status: "enrolling" } }, headers: auth(actor, @workspace), as: :json
    when "update"
      patch "/api/v1/admin/cohorts/#{@cohort.id}", params: { cohort: { name: "Unauthorized rename", expected_updated_at: @cohort.updated_at.iso8601(6) } }, headers: auth(actor, @workspace), as: :json
    when "remove"
      delete enrollment_url, params: { expected_membership_id: @membership.id }, headers: auth(actor, @workspace), as: :json
    end
  end

  def enrollment_url
    "/api/v1/admin/cohorts/#{@cohort.id}/participants/#{@participant.id}"
  end

  def user(label, role)
    User.create!(email: "#{label}@example.com", clerk_id: "clerk_#{SecureRandom.hex(6)}", role: role, invitation_status: "accepted")
  end

  def auth(user, workspace = nil)
    { "Authorization" => "Bearer test_token_#{user.id}" }.tap { |headers| headers["X-Coach-Workspace-Id"] = workspace.id.to_s if workspace }
  end
end
