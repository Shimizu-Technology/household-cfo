# frozen_string_literal: true

require "test_helper"
require "timeout"

class CohortMembershipConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent cohort grants and last removals leave one accurate derived workspace membership" do
    suffix = SecureRandom.hex(6)
    owner = create_staff("owner-#{suffix}")
    staff = create_staff("staff-#{suffix}")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohorts = 2.times.map do |index|
      Cohort.create!(
        name: "Concurrent workspace cohort #{suffix} #{index}",
        status: "active",
        created_by_user: owner,
        coach_workspace: workspace
      )
    end

    concurrently(cohorts) do |cohort|
      CohortMembership.create!(user_id: staff.id, cohort_id: cohort.id, role: "coach")
    end
    derived = workspace.coach_workspace_memberships.where(user: staff)
    assert_equal 1, derived.count
    assert_predicate derived.sole, :cohort_managed?

    original = CohortMembership.method(:reconcile_workspace_access!)
    arrived = Queue.new
    release = Queue.new
    CohortMembership.define_singleton_method(:reconcile_workspace_access!) do |locked_workspace, locked_user|
      arrived << true
      release.pop
      original.call(locked_workspace, locked_user)
    end
    memberships = staff.cohort_memberships.where(cohort: cohorts).to_a
    errors = Queue.new
    threads = memberships.map do |membership|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          CohortMembership.find(membership.id).destroy!
        rescue StandardError => error
          errors << error
        end
      end
    end
    Timeout.timeout(3) { memberships.length.times { arrived.pop } }
    memberships.length.times { release << true }
    threads.each { |thread| thread.join(5) }

    assert threads.none?(&:alive?), "concurrent membership removals did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_nil workspace.coach_workspace_memberships.find_by(user: staff)
  ensure
    CohortMembership.define_singleton_method(:reconcile_workspace_access!, original) if defined?(original) && original
    memberships&.length&.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
    CohortMembership.where(user_id: staff&.id).delete_all
    CoachWorkspaceMembership.where(user_id: staff&.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    Cohort.where(id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ staff&.id, owner&.id ].compact).delete_all
  end

  private

  def concurrently(values)
    ready = Queue.new
    release = Queue.new
    errors = Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield value
        rescue StandardError => error
          errors << error
        end
      end
    end
    Timeout.timeout(3) { values.length.times { ready.pop } }
    values.length.times { release << true }
    threads.each { |thread| thread.join(5) }
    assert threads.none?(&:alive?), "concurrent membership changes did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
  ensure
    values.length.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
  end

  def create_staff(label)
    User.create!(
      clerk_id: "clerk_#{label}",
      email: "#{label}@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
  end
end
