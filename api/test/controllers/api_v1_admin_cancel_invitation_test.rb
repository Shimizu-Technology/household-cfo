# frozen_string_literal: true

require "test_helper"

# A program owner may cancel a pending participant invitation that sits wholly inside their program.
# Everything else stays with the administrator's existing status change.
class ApiV1AdminCancelInvitationTest < ActionDispatch::IntegrationTest
  setup do
    @owner = user("cancel-owner", "coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @group = Cohort.create!(name: "Cancel group", status: "enrolling", created_by_user: @owner, coach_workspace: @workspace)
    @invitee = pending_participant("cancel-invitee", @group)
  end

  test "an owner cancels a pending invitation: it is revoked, the seats are removed and the action is recorded" do
    assert_difference -> { ParticipantInvitationCancellation.count }, 1 do
      post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    end
    assert_response :success
    assert response.parsed_body.fetch("cancelled")
    assert_equal "revoked", @invitee.reload.invitation_status
    assert_empty @invitee.cohort_memberships
    record = ParticipantInvitationCancellation.order(:id).last
    assert_equal [ @owner.id, @invitee.id, @workspace.id ], [ record.actor_user_id, record.subject_user_id, record.coach_workspace_id ]
    assert_equal [ { "id" => @group.id, "name" => "Cancel group" } ], record.groups
    assert_equal @invitee.email, record.subject_email

    get "/api/v1/admin/users", headers: auth(@owner, @workspace)
    refute_includes response.parsed_body.fetch("users").map { |row| row.fetch("id") }, @invitee.id
  end

  test "the record cannot be edited or deleted" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    record = ParticipantInvitationCancellation.order(:id).last
    assert_not record.update(subject_email: "changed@example.test")
    assert_not record.destroy
    assert_equal 1, ParticipantInvitationCancellation.where(id: record.id).count
  end

  test "someone who already joined is refused and keeps their group" do
    joined = user("cancel-joined", "participant")
    @group.cohort_memberships.create!(user: joined, role: "participant")
    post "/api/v1/admin/users/#{joined.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "accepted", joined.reload.invitation_status
    assert_equal 1, joined.cohort_memberships.count
    assert_no_difference -> { ParticipantInvitationCancellation.count } do
      post "/api/v1/admin/users/#{joined.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    end
  end

  test "an invitee who is also in another program is left alone" do
    other_owner = user("cancel-other-owner", "coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    other = Cohort.create!(name: "Someone else's group", status: "active", created_by_user: other_owner, coach_workspace: other_workspace)
    other.cohort_memberships.create!(user: @invitee, role: "participant")
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "pending", @invitee.reload.invitation_status
    assert_equal 2, @invitee.cohort_memberships.count
    refute_includes response.body, other.name
  end

  test "someone in another program cannot cancel it" do
    stranger = user("cancel-stranger", "coach")
    stranger_workspace = CoachWorkspaces::Provisioner.ensure_for!(stranger)
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(stranger, stranger_workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "pending", @invitee.reload.invitation_status
    assert_equal 1, @invitee.cohort_memberships.count
  end

  test "editors, reviewers and viewers cannot cancel an invitation" do
    %w[editor reviewer viewer].each do |role|
      collaborator = user("cancel-#{role}", "coach")
      @workspace.coach_workspace_memberships.create!(user: collaborator, role: role)
      @group.cohort_memberships.create!(user: collaborator, role: "coach")
      post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(collaborator, @workspace), as: :json
      assert_response :forbidden, role
      assert_equal "pending", @invitee.reload.invitation_status
    end
  end

  test "a person who works on the team is not an invitee to cancel" do
    colleague = user("cancel-colleague", "coach")
    colleague.update!(invitation_status: "pending")
    @workspace.coach_workspace_memberships.create!(user: colleague, role: "editor")
    post "/api/v1/admin/users/#{colleague.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
    assert_equal "pending", colleague.reload.invitation_status
  end

  test "an administrator in a program can cancel it too, and without a program is asked to choose one" do
    admin = user("cancel-admin", "admin")
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")
    assert_equal "pending", @invitee.reload.invitation_status
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(admin, @workspace), as: :json
    assert_response :success
    assert_equal "revoked", @invitee.reload.invitation_status
  end

  test "cancelling twice says it was already cancelled" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :success
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
  end

  private

  def user(label, role)
    User.create!(email: "#{label}@example.com", clerk_id: "clerk_#{SecureRandom.hex(6)}", role: role, invitation_status: "accepted")
  end

  def auth(user, workspace = nil)
    { "Authorization" => "Bearer test_token_#{user.id}" }.tap { |headers| headers["X-Coach-Workspace-Id"] = workspace.id.to_s if workspace }
  end

  def pending_participant(key, group)
    person = user(key, "participant")
    person.update!(invitation_status: "pending", invited_at: 1.day.ago, invited_by_user: @owner)
    group.cohort_memberships.create!(user: person, role: "participant")
    person
  end
end
