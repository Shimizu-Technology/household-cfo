# frozen_string_literal: true

require "test_helper"
require "timeout"

class CohortReleasesConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent retries seal one release and conflicting requests receive monotonic numbers" do
    suffix = SecureRandom.hex(6)
    owner = User.create!(
      clerk_id: "release_concurrency_#{suffix}",
      email: "release-concurrency-#{suffix}@example.com",
      role: "coach",
      invitation_status: "accepted"
    )
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Release concurrency #{suffix}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )

    same_request = concurrently(4.times.map { "same-request" }) do |request_key|
      CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: nil, publication_source: "system").call!(
        request_key: request_key,
        event_type: "reconciliation"
      )
    end
    assert_equal 1, same_request.map(&:id).uniq.length
    assert_equal 1, cohort.cohort_releases.count

    separate_requests = concurrently(%w[second-request third-request]) do |request_key|
      CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: nil, publication_source: "system").call!(
        request_key: request_key,
        event_type: "reconciliation"
      )
    end
    assert_equal 2, separate_requests.map(&:id).uniq.length
    assert_equal [ 1, 2, 3 ], cohort.cohort_releases.order(:release_number).pluck(:release_number)
    assert cohort.cohort_releases.all?(&:integrity_valid?)
  ensure
    if CohortRelease.table_exists?
      begin
        CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable")
        CohortRelease.where(cohort_id: cohort&.id).delete_all
      ensure
        CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable")
      end
    end
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: owner&.id).delete_all
  end

  test "a membership downgrade that wins the lock race revokes release authority" do
    suffix = SecureRandom.hex(6)
    owner = create_staff("release-owner-#{suffix}")
    reviewer = create_staff("release-reviewer-#{suffix}")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    cohort = Cohort.create!(name: "Release authority #{suffix}", status: "active",
      created_by_user: owner, coach_workspace: workspace)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    membership_locked = Queue.new
    allow_downgrade = Queue.new
    sealer_started = Queue.new
    sealer_result = Queue.new

    downgrade_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CoachWorkspaceMembership.transaction do
          locked = CoachWorkspaceMembership.lock.find(membership.id)
          membership_locked << true
          allow_downgrade.pop
          locked.update!(role: "viewer")
        end
      end
    end
    Timeout.timeout(5) { membership_locked.pop }
    sealer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sealer_started << true
        result = begin
          CohortReleases::Sealer.new(cohort: Cohort.find(cohort.id), actor: User.find(reviewer.id)).call!(
            request_key: "revoked-reviewer",
            expected_bundle_digest: candidate.bundle_digest
          )
        rescue StandardError => error
          error
        end
        sealer_result << result
      end
    end
    Timeout.timeout(5) { sealer_started.pop }
    allow_downgrade << true
    downgrade_thread.join(10)
    sealer_thread.join(10)

    assert_not downgrade_thread.alive?
    assert_not sealer_thread.alive?
    assert_instance_of CohortReleases::Sealer::NotAuthorized, Timeout.timeout(5) { sealer_result.pop }
    assert_empty cohort.cohort_releases
    assert_equal "viewer", membership.reload.role
  ensure
    allow_downgrade << true if defined?(allow_downgrade)
    downgrade_thread&.join(1)
    sealer_thread&.join(1)
    CohortRelease.connection.execute("ALTER TABLE cohort_releases DISABLE TRIGGER cohort_releases_immutable") if CohortRelease.table_exists?
    CohortRelease.where(cohort_id: cohort&.id).delete_all if CohortRelease.table_exists?
    CohortRelease.connection.execute("ALTER TABLE cohort_releases ENABLE TRIGGER cohort_releases_immutable") if CohortRelease.table_exists?
    CohortExperienceConfiguration.where(cohort_id: cohort&.id).delete_all
    Cohort.where(id: cohort&.id).delete_all
    CoachProfile.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: workspace&.id).delete_all
    CoachWorkspace.where(id: workspace&.id).delete_all
    User.where(id: [ owner&.id, reviewer&.id ].compact).delete_all
  end

  private

  def concurrently(values)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << yield(value)
        rescue StandardError => error
          errors << error
        end
      end
    end
    Timeout.timeout(5) { values.length.times { ready.pop } }
    values.length.times { release << true }
    threads.each { |thread| thread.join(10) }

    assert threads.none?(&:alive?), "concurrent cohort release sealing did not finish"
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    values.length.times.map { results.pop }
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
