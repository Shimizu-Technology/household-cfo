require "test_helper"
require "timeout"

class ApiV1AdminUsersInvitationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "simultaneous additive invitations retain both new cohort memberships" do
    suffix = SecureRandom.hex(6)
    admin = User.create!(
      clerk_id: "clerk_invitation_admin_#{suffix}",
      email: "invitation-admin-#{suffix}@example.com",
      role: "admin",
      invitation_status: "accepted"
    )
    participant = User.create!(
      clerk_id: "clerk_invitation_participant_#{suffix}",
      email: "invitation-participant-#{suffix}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    cohorts = %w[Existing First Second].map do |name|
      Cohort.create!(name: "#{name} #{suffix}", status: "active", created_by_user: admin)
    end
    participant.cohort_memberships.create!(cohort: cohorts.first, role: "participant")

    snapshots = Queue.new
    release = Queue.new
    errors = Queue.new
    threads = cohorts.drop(1).map do |requested_cohort|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          concurrent_user = User.find(participant.id)
          controller = Api::V1::Admin::UsersController.new
          original_target_ids = controller.method(:invitation_target_cohort_ids)
          first_snapshot = true
          controller.define_singleton_method(:invitation_target_cohort_ids) do |user, **options|
            ids = original_target_ids.call(user, **options)
            if first_snapshot
              first_snapshot = false
              snapshots << ids
              release.pop
            end
            ids
          end

          controller.send(
            :with_stable_invitation_membership_locks,
            concurrent_user,
            requested_cohort_ids: [ requested_cohort.id ],
            replace_memberships: false
          ) do |target_cohort_ids|
            controller.send(
              :sync_cohort_memberships,
              concurrent_user,
              target_cohort_ids,
              role: "participant"
            )
          end
        rescue StandardError => e
          errors << e
        end
      end
    end

    initial_snapshots = Timeout.timeout(3) { 2.times.map { snapshots.pop } }
    expected_snapshots = [
      [ cohorts.first.id, cohorts.second.id ],
      [ cohorts.first.id, cohorts.third.id ]
    ].map(&:sort).sort
    assert_equal expected_snapshots, initial_snapshots.map(&:sort).sort
    2.times { release << true }
    threads.each { |thread| thread.join(3) }

    assert threads.none?(&:alive?), "concurrent invitations did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_equal cohorts.map(&:id).sort, participant.reload.cohort_ids.sort
  ensure
    2.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
    CohortMembership.where(user_id: participant&.id).delete_all
    Cohort.where(id: cohorts&.map(&:id)).delete_all if defined?(cohorts)
    User.where(id: [ participant&.id, admin&.id ].compact).delete_all
  end
end
