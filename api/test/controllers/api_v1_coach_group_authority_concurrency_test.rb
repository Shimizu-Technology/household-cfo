# frozen_string_literal: true

require "test_helper"
require "timeout"

class ApiV1CoachGroupAuthorityConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  %w[demotion revocation].each do |change|
    test "concurrent #{change} after group authorization blocks the pending rename" do
      actor = create_user(change == "revocation" ? "admin" : "coach")
      successor = create_user("coach")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(actor)
      workspace.coach_workspace_memberships.create!(user: successor, role: "owner")
      cohort = Cohort.create!(name: "Concurrent group authority", status: "enrolling", created_by_user: actor, coach_workspace: workspace)
      controller = Api::V1::Admin::CohortsController
      original = controller.instance_method(:require_group_management!)
      authorized = Queue.new
      continue_request = Queue.new
      results = Queue.new
      errors = Queue.new
      controller.define_method(:require_group_management!) do
        original.bind_call(self)
        if Thread.current[:group_authority_request] && !performed?
          authorized << true
          continue_request.pop
        end
      end
      request_thread = nil
      workspace.with_lock do
        request_thread = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Thread.current[:group_authority_request] = true
            session = ActionDispatch::Integration::Session.new(Rails.application)
            session.patch "/api/v1/admin/cohorts/#{cohort.id}", params: {
              cohort: { name: "Unauthorized pending rename", expected_updated_at: cohort.updated_at.iso8601(6) }
            }, headers: { "Authorization" => "Bearer test_token_#{actor.id}", "X-Coach-Workspace-Id" => workspace.id.to_s }, as: :json
            results << session.response.status
          rescue StandardError => error
            errors << error
          end
        end
        Timeout.timeout(5) { authorized.pop }
        if change == "demotion"
          member = workspace.coach_workspace_memberships.find_by!(user: actor)
          CoachWorkspaces::Collaborators.new(workspace: workspace, actor: successor).change(id: member.id, role: "editor", expected_role: "owner")
        else
          User.find(actor.id).update!(invitation_status: "revoked")
        end
      end
      continue_request << true
      request_thread.join(10)
      assert_not request_thread.alive?, "Pending group update did not finish"
      assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
      assert_equal 404, results.pop
      assert_equal "Concurrent group authority", cohort.reload.name
    ensure
      continue_request << true if defined?(continue_request) && continue_request
      request_thread&.join(10)
      if defined?(original) && original
        controller.define_method(:require_group_management!, original)
        controller.send(:private, :require_group_management!)
      end
      delete_workspace_membership_events(workspace&.id)
      CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
      Cohort.where(id: cohort&.id).delete_all
      CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
      CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
      delete_workspace_brand_records(workspace&.id)
      CoachWorkspace.where(id: workspace&.id).delete_all
      User.where(id: [ actor&.id, successor&.id ].compact).delete_all
    end
  end

  private

  def create_user(role)
    suffix = SecureRandom.hex(7)
    User.create!(clerk_id: "group-authority-#{suffix}", email: "#{suffix}@example.test", role: role)
  end
end
