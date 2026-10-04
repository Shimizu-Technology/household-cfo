require "test_helper"
require "timeout"

class ApiV1InvitationDeliveryLockTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "resend provider call releases cohort workspace actor and subject locks" do
    actor = User.create!(email: "delivery-owner-#{SecureRandom.hex(6)}@example.test", clerk_id: "delivery_owner_#{SecureRandom.hex(6)}", role: "coach")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(actor)
    cohort = Cohort.create!(name: "Delivery locks", created_by_user: actor, coach_workspace: workspace)
    pending = User.create!(email: "delivery-pending-#{SecureRandom.hex(6)}@example.test", clerk_id: "pending_#{SecureRandom.hex(6)}", role: "participant", invitation_status: "pending")
    pending.cohort_memberships.create!(cohort: cohort, role: "participant")
    provider_called = false
    lock_acquired = false
    errors = Queue.new
    original = UserInviteEmailService.method(:send_invite)
    UserInviteEmailService.define_singleton_method(:send_invite) do |**_arguments|
      provider_called = true
      checking = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            connection.execute("SET LOCAL lock_timeout = '1s'")
            Cohort.where(id: cohort.id).lock("FOR UPDATE NOWAIT").load
            CoachWorkspace.where(id: workspace.id).lock("FOR UPDATE NOWAIT").load
            User.where(id: [ actor.id, pending.id ]).order(:id).lock("FOR UPDATE NOWAIT").load
            lock_acquired = true
          end
        end
      rescue StandardError => error
        errors << error
      end
      checking.join(3)
      { sent: false, status: "failed", error: "Mock unavailable provider" }
    end
    post "/api/v1/admin/users/#{pending.id}/resend_invitation",
      headers: { "Authorization" => "Bearer test_token_#{actor.id}", "X-Coach-Workspace-Id" => workspace.id.to_s }
    assert_response :success
    assert provider_called
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert lock_acquired, "Roster locks remained held during provider delivery"
    assert_equal "failed", pending.invitation_email_attempts.last.status
  ensure
    UserInviteEmailService.define_singleton_method(:send_invite, original) if original
    InvitationEmailAttempt.where(user_id: pending&.id).delete_all
    CohortMembership.where(cohort_id: cohort&.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    delete_workspace_membership_events(workspace&.id)
    delete_workspace_brand_records(workspace&.id)
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ actor&.id, pending&.id ].compact).delete_all
  end
end
