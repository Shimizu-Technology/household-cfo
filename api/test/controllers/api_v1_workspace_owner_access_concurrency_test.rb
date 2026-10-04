require "test_helper"
require "timeout"

class ApiV1WorkspaceOwnerAccessConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "simultaneous global revocations cannot remove both active workspace owners" do
    suffix = SecureRandom.hex(6)
    admin, first_owner, second_owner = %w[admin coach coach].map.with_index do |role, index|
      User.create!(email: "owner-race-#{suffix}-#{index}@example.test", clerk_id: "clerk_#{suffix}_#{index}", role: role, invitation_status: "accepted")
    end
    workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    workspace.coach_workspace_memberships.create!(user: second_owner, role: "owner")
    cohorts = [first_owner, second_owner].map.with_index do |owner, index|
      cohort = Cohort.create!(name: "Owner race #{suffix}-#{index}", created_by_user: first_owner, coach_workspace: workspace)
      cohort.cohort_memberships.create!(user: owner, role: "coach")
      cohort
    end
    # Initialize the test Rack stack before concurrent requests. Production
    # eager-loads this stack; development's first request is not the lock test.
    warmup = ActionDispatch::Integration::Session.new(Rails.application)
    warmup.get("/api/v1/admin/users", headers: { "Authorization" => "Bearer test_token_#{admin.id}" })
    assert_equal 200, warmup.response.status
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = [first_owner, second_owner].map do |owner|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.patch("/api/v1/admin/users/#{owner.id}", params: { user: { invitation_status: "revoked" } },
            headers: { "Authorization" => "Bearer test_token_#{admin.id}" }, as: :json)
          results << [session.response.status, session.response.body]
        rescue StandardError => error
          results << error
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { start << true }
    threads.each { |thread| thread.join(10) }
    assert threads.none?(&:alive?), "Concurrent owner account changes did not finish."
    responses = 2.times.map { results.pop }
    assert_equal [200, 422], responses.map(&:first).sort, responses.inspect
    assert_equal 1, workspace.coach_workspace_memberships.joins(:user).where(role: "owner", users: { invitation_status: "accepted" }).count
  ensure
    2.times { start << true } if defined?(start)
    threads&.each { |thread| thread.join(2) }
    CohortMembership.where(cohort_id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    CohortExperienceConfiguration.where(cohort_id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    Cohort.where(id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    delete_empty_coach_workspaces_for_users([first_owner&.id])
    User.where(id: [admin&.id, first_owner&.id, second_owner&.id].compact).delete_all
  end
end
