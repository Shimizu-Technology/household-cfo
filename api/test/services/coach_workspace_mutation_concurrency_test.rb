# frozen_string_literal: true

require "test_helper"
require "timeout"

class CoachWorkspaceMutationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "reviewer release authorization and owner demotion finish without inverted user membership locks" do
    owner = create_user
    reviewer = create_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    cohort = Cohort.create!(name: "Authority concurrency", status: "active", created_by_user: owner, coach_workspace: workspace)
    locked = Queue.new
    continue_release = Queue.new
    backend = Queue.new
    errors = Queue.new
    authorized = Queue.new

    releasing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.lock.find(reviewer.id)
          locked << true
          continue_release.pop
          actor, role = CohortReleases::Authorization.new(cohort: Cohort.find(cohort.id), actor: reviewer).call!
          authorized << [ actor.id, role ]
        end
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(5) { locked.pop }
    demoting = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value("SELECT pg_backend_pid()")
        CoachWorkspaces::Collaborators.new(workspace: CoachWorkspace.find(workspace.id), actor: owner).change(
          id: membership.id, role: "viewer", expected_role: "reviewer")
      rescue StandardError => error
        errors << error
      end
    end
    pid = Timeout.timeout(5) { backend.pop }
    # Wait for demotion to block on the reviewer user, then let publication
    # acquire its membership. The former membership->user order deadlocks here.
    Timeout.timeout(5) do
      loop do
        waiting = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_one("SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        end
        break if waiting["wait_event_type"] == "Lock" && waiting["query"].include?('"users"')

        Thread.pass
      end
    end
    continue_release << true
    [ releasing, demoting ].each { |thread| thread.join(10) }
    assert [ releasing, demoting ].none?(&:alive?), "Concurrent publication and demotion did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_equal [ reviewer.id, "reviewer" ], authorized.pop
    assert_equal "viewer", membership.reload.role
    assert_raises(CohortReleases::Authorization::NotAuthorized) do
      User.transaction { CohortReleases::Authorization.new(cohort: cohort, actor: reviewer).call! }
    end
  ensure
    continue_release << true if defined?(continue_release) && continue_release
    [ releasing, demoting ].compact.each { |thread| thread.join(10) }
    CoachWorkspaceMembershipEvent.where(coach_workspace_id: workspace&.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    delete_workspace_brand_records(workspace&.id)
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ owner&.id, reviewer&.id ].compact).delete_all
  end

  test "explicit removal cannot invert reconciliation advisory and membership locks" do
    owner = create_user
    collaborator = create_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Removal concurrency", status: "active", created_by_user: owner, coach_workspace: workspace)
    CohortMembership.create!(user: collaborator, cohort: cohort, role: "coach")
    membership = workspace.coach_workspace_memberships.find_by!(user: collaborator)
    locked = Queue.new
    reconcile = Queue.new
    backend = Queue.new
    completed = Queue.new
    errors = Queue.new
    reconciling = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        CohortMembership.transaction do
          connection.execute("SELECT pg_advisory_xact_lock(#{workspace.id}, #{collaborator.id})")
          locked << true
          reconcile.pop
          CohortMembership.reconcile_workspace_access!(CoachWorkspace.find(workspace.id), User.find(collaborator.id))
        end
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(5) { locked.pop }
    removing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value("SELECT pg_backend_pid()")
        CoachWorkspaces::Collaborators.new(workspace: CoachWorkspace.find(workspace.id), actor: owner).remove(
          id: membership.id, expected_role: "editor")
        completed << true
      rescue StandardError => error
        errors << error
      end
    end
    pid = Timeout.timeout(5) { backend.pop }
    Timeout.timeout(5) do
      loop do
        break unless completed.empty? && errors.empty?

        waiting = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_one("SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        end
        break if waiting["wait_event_type"] == "Lock" && waiting["query"].include?("pg_advisory_xact_lock")

        Thread.pass
      end
    end
    reconcile << true
    [ reconciling, removing ].each { |thread| thread.join(10) }
    assert [ reconciling, removing ].none?(&:alive?), "Concurrent reconciliation and removal did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_not CoachWorkspaceMembership.exists?(membership.id)
    assert_not CohortMembership.exists?(cohort: cohort, user: collaborator)
  ensure
    reconcile << true if defined?(reconcile) && reconcile
    [ reconciling, removing ].compact.each { |thread| thread.join(10) }
    CoachWorkspaceMembershipEvent.where(coach_workspace_id: workspace&.id).delete_all
    CohortMembership.where(cohort_id: cohort&.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    delete_workspace_brand_records(workspace&.id)
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ owner&.id, collaborator&.id ].compact).delete_all
  end

  private

  def create_user
    suffix = SecureRandom.hex(8)
    User.create!(clerk_id: "authority-concurrent-#{suffix}", email: "#{suffix}@example.test", role: "coach")
  end
end
