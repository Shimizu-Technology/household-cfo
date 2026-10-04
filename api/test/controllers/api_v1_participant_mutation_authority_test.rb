# frozen_string_literal: true

require "test_helper"

class ApiV1ParticipantMutationAuthorityTest < ActionDispatch::IntegrationTest
  setup do
    @owner = account("coach")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @cohort = Cohort.create!(name: "Authority participants", status: "enrolling", created_by_user: @owner, coach_workspace: @workspace)
    @participant = account("participant")
    @participant.cohort_memberships.create!(cohort: @cohort, role: "participant")
    @pending = User.create!(clerk_id: "pending_#{SecureRandom.uuid}", email: "#{SecureRandom.hex(7)}@example.test", role: "participant", invitation_status: "pending")
    @pending.cohort_memberships.create!(cohort: @cohort, role: "participant")
    @unattached = account("participant")
  end

  %w[new attach update resend].each do |action|
    %w[demotion revocation].each do |change|
      test "late #{change} denies participant #{action} without account enrollment or email changes" do
        actor = change == "demotion" ? @owner : account("admin")
        method = if action == "new"
          :create_new_invited_user
        elsif action == "attach" && change == "demotion"
          :attach_existing_participant
        else
          :with_stable_membership_locks
        end
        intercept_mutation(method) do
          if change == "demotion"
            @workspace.membership_for(actor).update!(role: "editor")
          else
            User.find(actor.id).update!(invitation_status: "revoked")
          end
        end
        participant_snapshot = @participant.attributes.slice("first_name", "role", "invitation_status", "invited_by_user_id")
        pending_snapshot = @pending.attributes.slice("invitation_status", "last_invite_email_attempted_at", "last_invite_email_sent_by_user_id")
        assert_no_difference [ "User.count", "CohortMembership.count", "InvitationEmailAttempt.count" ] do
          submit_mutation(action, actor)
          assert_response :forbidden
        end
        assert_equal participant_snapshot, @participant.reload.attributes.slice(*participant_snapshot.keys)
        assert_equal pending_snapshot, @pending.reload.attributes.slice(*pending_snapshot.keys)
        assert_empty @unattached.cohort_memberships.reload
      end
    end
  end

  teardown do
    if @intercepted_method
      controller = Api::V1::Admin::UsersController
      controller.define_method(@intercepted_method, @original_method)
      controller.send(:private, @intercepted_method)
    end
  end

  private

  def intercept_mutation(method, &change)
    @intercepted_method = method
    controller = Api::V1::Admin::UsersController
    @original_method = controller.instance_method(method)
    original = @original_method
    changed = false
    controller.define_method(method) do |*args, **options, &block|
      unless changed
        changed = true
        change.call
      end
      original.bind_call(self, *args, **options, &block)
    end
    controller.send(:private, method)
  end

  def submit_mutation(action, actor)
    headers = { "Authorization" => "Bearer test_token_#{actor.id}", "X-Coach-Workspace-Id" => @workspace.id.to_s }
    case action
    when "new", "attach"
      email = action == "new" ? "new-after-check@example.test" : @unattached.email
      post "/api/v1/admin/users", params: { user: { email: email, role: "participant", cohort_id: @cohort.id, send_invitation_email: false } }, headers: headers, as: :json
    when "update"
      patch "/api/v1/admin/users/#{@participant.id}", params: { user: { first_name: "Unauthorized name" } }, headers: headers, as: :json
    when "resend"
      post "/api/v1/admin/users/#{@pending.id}/resend_invitation", headers: headers
    end
  end

  def account(role)
    suffix = SecureRandom.hex(8)
    User.create!(clerk_id: "participant-authority-#{suffix}", email: "#{suffix}@example.test", role: role)
  end
end
