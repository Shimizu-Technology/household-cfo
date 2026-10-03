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
    delete_workspace_brand_records(workspace&.id)
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ staff&.id, owner&.id ].compact).delete_all
  end

  test "opposite dual transfers lock access pairs in one order and leave accurate derived memberships" do
    suffix = SecureRandom.hex(6)
    first_owner = create_staff("opposite-first-owner-#{suffix}")
    second_owner = create_staff("opposite-second-owner-#{suffix}")
    first_staff = create_staff("opposite-first-staff-#{suffix}")
    second_staff = create_staff("opposite-second-staff-#{suffix}")
    first_workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    second_workspace = CoachWorkspaces::Provisioner.ensure_for!(second_owner)
    cohorts = [
      Cohort.create!(name: "Opposite first old #{suffix}", status: "active", created_by_user: first_owner, coach_workspace: first_workspace),
      Cohort.create!(name: "Opposite second target #{suffix}", status: "active", created_by_user: second_owner, coach_workspace: second_workspace),
      Cohort.create!(name: "Opposite second old #{suffix}", status: "active", created_by_user: second_owner, coach_workspace: second_workspace),
      Cohort.create!(name: "Opposite first target #{suffix}", status: "active", created_by_user: first_owner, coach_workspace: first_workspace)
    ]
    first_membership = CohortMembership.create!(cohort: cohorts[0], user: first_staff, role: "coach")
    second_membership = CohortMembership.create!(cohort: cohorts[2], user: second_staff, role: "coach")

    concurrently([
      [ first_membership.id, cohorts[1].id, second_staff.id ],
      [ second_membership.id, cohorts[3].id, first_staff.id ]
    ]) do |membership_id, cohort_id, user_id|
      CohortMembership.find(membership_id).update!(cohort_id: cohort_id, user_id: user_id)
    end

    assert_equal [ [ first_workspace.id, first_staff.id ], [ second_workspace.id, second_staff.id ] ],
      CoachWorkspaceMembership.where(user: [ first_staff, second_staff ], cohort_managed: true)
        .order(:coach_workspace_id, :user_id).pluck(:coach_workspace_id, :user_id)
    assert_nil first_workspace.coach_workspace_memberships.find_by(user: second_staff)
    assert_nil second_workspace.coach_workspace_memberships.find_by(user: first_staff)
  ensure
    CohortMembership.where(id: [ first_membership&.id, second_membership&.id ].compact).delete_all
    CoachWorkspaceMembership.where(user_id: [ first_staff&.id, second_staff&.id ].compact).delete_all
    CohortExperienceConfiguration.where(cohort_id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    Cohort.where(id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    workspace_ids = [ first_workspace&.id, second_workspace&.id ].compact
    CoachProfile.where(coach_workspace_id: workspace_ids).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace_ids).delete_all
    delete_workspace_brand_records(workspace_ids)
    CoachWorkspace.where(id: workspace_ids).delete_all
    User.where(id: [ first_staff&.id, second_staff&.id, first_owner&.id, second_owner&.id ].compact).delete_all
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
