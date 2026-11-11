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

  test "the database itself refuses to change or remove a cancellation" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    record = ParticipantInvitationCancellation.order(:id).last
    table = ParticipantInvitationCancellation.quoted_table_name
    [ "UPDATE #{table} SET subject_email = 'changed@example.test' WHERE id = #{record.id}", "DELETE FROM #{table} WHERE id = #{record.id}" ].each do |statement|
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(statement) }
      end
    end
    assert_equal @invitee.email, record.reload.subject_email
  end

  test "someone who accepted is refused even if their status still says pending" do
    accepted = pending_participant("cancel-accepted", @group)
    accepted.update!(accepted_at: 2.days.ago)
    assert_no_difference -> { ParticipantInvitationCancellation.count } do
      post "/api/v1/admin/users/#{accepted.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/already joined/, response.parsed_body.fetch("errors").first)
    assert_equal "pending", accepted.reload.invitation_status
    assert_equal 1, accepted.cohort_memberships.count
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

  test "someone in another program gets the same not-found for every kind of account, and learns nothing" do
    stranger = user("cancel-stranger", "coach")
    stranger_workspace = CoachWorkspaces::Provisioner.ensure_for!(stranger)
    staff = user("cancel-staff", "coach")
    joined = user("cancel-joined-elsewhere", "participant")
    @group.cohort_memberships.create!(user: joined, role: "participant")
    cancelled = pending_participant("cancel-cancelled-elsewhere", @group)
    post "/api/v1/admin/users/#{cancelled.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :success
    bodies = [ @invitee, staff, joined, cancelled ].map do |person|
      post "/api/v1/admin/users/#{person.id}/cancel_invitation", headers: auth(stranger, stranger_workspace), as: :json
      assert_response :not_found
      response.body
    end
    post "/api/v1/admin/users/0/cancel_invitation", headers: auth(stranger, stranger_workspace), as: :json
    assert_response :not_found
    assert_equal [ response.body ], bodies.uniq
    assert_equal "pending", @invitee.reload.invitation_status
    assert_equal 1, @invitee.cohort_memberships.count
    assert_equal 1, ParticipantInvitationCancellation.count
  end

  test "inside the program the specific reasons are still given" do
    joined = user("cancel-joined-here", "participant")
    @group.cohort_memberships.create!(user: joined, role: "participant")
    post "/api/v1/admin/users/#{joined.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").first, "already joined"
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").first, "already cancelled"
  end

  test "an owner can invite a person again after cancelling: pending again, in the chosen group, and recorded" do
    other_group = Cohort.create!(name: "Second group", status: "enrolling", created_by_user: @owner, coach_workspace: @workspace)
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert_difference -> { InvitationEmailAttempt.where(user_id: @invitee.id).count }, 1 do
      post "/api/v1/admin/users", params: { user: { email: @invitee.email.upcase, cohort_ids: [ other_group.id ] } }, headers: auth(@owner, @workspace), as: :json
    end
    assert_response :success
    assert_equal true, response.parsed_body.fetch("reactivated")
    @invitee.reload
    assert_equal "pending", @invitee.invitation_status
    assert_equal [ other_group.id ], @invitee.cohort_memberships.pluck(:cohort_id)
    assert_equal @owner.id, @invitee.invited_by_user_id
    assert_equal 1, ParticipantInvitationCancellation.count

    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_response :success
    assert_equal 2, ParticipantInvitationCancellation.where(subject_user_id: @invitee.id).count
    assert_equal "revoked", @invitee.reload.invitation_status
  end

  test "an owner of another program cannot invite a cancelled person" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    stranger = user("reinvite-stranger", "coach")
    stranger_workspace = CoachWorkspaces::Provisioner.ensure_for!(stranger)
    stranger_group = Cohort.create!(name: "Stranger group", status: "enrolling", created_by_user: stranger, coach_workspace: stranger_workspace)
    post "/api/v1/admin/users", params: { user: { email: @invitee.email, cohort_ids: [ stranger_group.id ] } }, headers: auth(stranger, stranger_workspace), as: :json
    assert_response :forbidden
    assert_equal "revoked", @invitee.reload.invitation_status
    assert_empty @invitee.cohort_memberships
  end

  test "someone an administrator turned off stays refused for owners, even in the same program" do
    person = pending_participant("reinvite-admin-revoked", @group)
    person.cohort_memberships.destroy_all
    person.update!(invitation_status: "revoked")
    post "/api/v1/admin/users", params: { user: { email: person.email, cohort_ids: [ @group.id ] } }, headers: auth(@owner, @workspace), as: :json
    assert_response :forbidden
    assert_equal "revoked", person.reload.invitation_status
    assert_empty person.cohort_memberships
  end

  test "a cancelled person who has since been seated in another program is not re-invited by an owner" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    other_owner = user("reinvite-other-owner", "coach")
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    other = Cohort.create!(name: "Admin placed", status: "active", created_by_user: other_owner, coach_workspace: other_workspace)
    other.cohort_memberships.create!(user: @invitee, role: "participant")
    post "/api/v1/admin/users", params: { user: { email: @invitee.email, cohort_ids: [ @group.id ] } }, headers: auth(@owner, @workspace), as: :json
    assert_response :forbidden
    assert_equal "revoked", @invitee.reload.invitation_status
  end

  test "deleting a person who appears in the cancellation record fails clearly" do
    post "/api/v1/admin/users/#{@invitee.id}/cancel_invitation", headers: auth(@owner, @workspace), as: :json
    assert_raises(ActiveRecord::DeleteRestrictionError) { @invitee.destroy }
    assert_raises(ActiveRecord::DeleteRestrictionError) { @owner.destroy }
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
