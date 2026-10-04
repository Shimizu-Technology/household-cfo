require "test_helper"
require "timeout"
require_relative "../support/savings_challenge_test_support"

class SavingsChallengeConcurrencyTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport
  self.use_transactional_tests = false

  setup do
    setup_savings_context
    @savings_cohort.update!(starts_on: Time.current.in_time_zone("Pacific/Guam").to_date)
    @owned_users = [ @savings_user, @savings_owner ]
    @owned_households = [ @savings_household ]
  end

  teardown do
    clear_owned_savings
    clear_owned_release_fixture
    CohortMembership.where(cohort_id: @savings_cohort.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: @savings_cohort.id).delete_all
    Cohort.where(id: @savings_cohort.id).delete_all
    @owned_households.each(&:destroy!)
    delete_empty_coach_workspaces_for_users(@owned_users.map(&:id))
    @owned_users.each { |user| user.reload.destroy! }
  end

  test "two independent households competing for the thirtieth seat serialize at the cohort lock" do
    with_savings_runtime do
      29.times do |index|
        user, household = index.zero? ? [ @savings_user, @savings_household ] : new_participant
        enroll_as(user, household)
      end
      candidates = 2.times.map { new_participant }
      outcomes = concurrently(candidates) { |user, household| enroll_as(user, household) }
      assert_equal 1, outcomes.count { |outcome| outcome.is_a?(HouseholdFinance::Operations::Runner::Result) }
      failures = outcomes.grep(ArgumentError)
      assert_equal 1, failures.size
      assert_includes failures.sole.message, "capacity"
      assert_equal 30, SavingsEnrollment.where(cohort_id: @savings_cohort.id).count
      assert_equal 1, SavingsEnrollment.where(cohort_id: @savings_cohort.id, user_id: candidates.map { |user, _| user.id }).count
    end
  end

  test "simultaneous same actor enrollment retries publish one acceptance and one redacted execution" do
    with_savings_runtime do
      outcomes = concurrently([ true, true ]) { enroll_as(@savings_user, @savings_household, token: "one-private-acceptance") }
      assert outcomes.all? { |outcome| outcome.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count(&:replayed?)
      assert_equal 1, SavingsEnrollment.where(cohort_id: @savings_cohort.id, user_id: @savings_user.id).count
      assert_equal 1, @savings_household.household_operation_executions.where(operation_key: "savings.enrollment.accept").count
      assert_equal 1, @savings_household.household_audit_events.where(event_type: "household_operation.executed").count
    end
  end

  test "competing corrections to one approved head preserve exactly one succeeding immutable revision" do
    with_savings_runtime do
      savings_enroll
      version = savings_approve(savings_draft(100))
      drafts = [ savings_draft(200, entry: version.savings_entry), savings_draft(300, entry: version.savings_entry) ]
      outcomes = concurrently(drafts.map(&:id)) do |id|
        draft = SavingsEntryDraft.find(id)
        savings_approve(draft)
      end
      assert_equal 1, outcomes.count { |outcome| outcome.is_a?(SavingsEntryVersion) }
      assert_equal 1, outcomes.count { |outcome| outcome.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 2, version.savings_entry.savings_entry_versions.count
      assert_equal 1, SavingsEntryDraft.where(id: drafts.map(&:id), status: "approved").count
      assert_includes [ 200, 300 ], savings_projection[:reported_cents]
      assert_equal 100, SavingsChallenge::Projection.new(@savings_enrollment.reload, approval_sequence: version.approval_sequence).call[:reported_cents]
    end
  end

  test "a committed cohort hold wins before an approval waiting on the same policy row" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      arrived, release = Queue.new, Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Cohort.transaction do
            Cohort.lock.find(@savings_cohort.id).update!(savings_challenge_release_hold: true)
            arrived << true
            release.pop
          end
        end
      end
      Timeout.timeout(10) { arrived.pop }
      connection = ActiveRecord::Base.connection
      connection.execute("SET lock_timeout = '500ms'")
      assert_raises(ActiveRecord::LockWaitTimeout) { savings_approve(draft) }
      connection.execute("SET lock_timeout = DEFAULT")
      release << true
      holder.value
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { savings_approve(draft) }
      assert_nil draft.reload.approved_version_id
      assert_equal 0, @savings_enrollment.savings_entry_versions.count
    ensure
      connection&.execute("SET lock_timeout = DEFAULT")
      release << true if holder&.alive?
      holder&.join(10)
    end
  end

  private

  def new_participant
    user = User.create!(clerk_id: "capacity-#{SecureRandom.hex(8)}", email: "capacity-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    @savings_cohort.cohort_memberships.create!(user: user, role: "participant")
    @owned_users << user
    @owned_households << household
    [ user, household ]
  end

  def enroll_as(user, household, token: SecureRandom.uuid)
    savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: false, expected_acceptance_digest: savings_offer_digest(user: user) },
      token: token, user: User.find(user.id), household: Household.find(household.id))
  end

  def concurrently(values)
    ready, release = Queue.new, Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield(*Array(value))
        rescue StandardError => error
          error
        end
      end
    end
    Timeout.timeout(10) { values.length.times { ready.pop } }
    values.length.times { release << true }
    threads.each { |thread| thread.join(20) }
    assert threads.none?(&:alive?), "Savings operations did not finish within the bounded concurrency test"
    threads.map(&:value)
  ensure
    values.length.times { release << true }
    threads&.each { |thread| thread.join(1) }
  end

  def clear_owned_release_fixture
    connection = ActiveRecord::Base.connection
    tables = %w[cohorts cohort_release_activation_events cohort_releases cohort_experience_versions cohort_experience_publication_events]
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
      @savings_cohort.update_columns(active_cohort_release_id: nil)
      CohortReleaseActivationEvent.where(cohort_id: @savings_cohort.id).delete_all
      CohortRelease.where(cohort_id: @savings_cohort.id).delete_all
      configuration = @savings_cohort.cohort_experience_configuration
      configuration.update_columns(current_published_version_id: nil)
      CohortExperiencePublicationEvent.where(cohort_experience_configuration_id: configuration.id).delete_all
      CohortExperienceVersion.where(cohort_experience_configuration_id: configuration.id).delete_all
      tables.each { |table| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER USER") }
    end
  end

  def clear_owned_savings
    connection = ActiveRecord::Base.connection
    tables = %w[savings_enrollments savings_entries savings_entry_versions savings_plan_versions savings_zero_attestations savings_entry_drafts savings_plan_drafts]
    enrollment_ids = SavingsEnrollment.where(cohort_id: @savings_cohort.id).pluck(:id)
    entry_ids = SavingsEntry.where(savings_enrollment_id: enrollment_ids).pluck(:id)
    # Only this disposable database's synthetic rows; every thread has joined.
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
      SavingsEnrollment.where(id: enrollment_ids).update_all(current_accepted_plan_version_id: nil)
      SavingsEntry.where(id: entry_ids).update_all(current_approved_version_id: nil)
      SavingsEntryDraft.where(savings_entry_id: entry_ids).delete_all
      SavingsPlanDraft.where(savings_enrollment_id: enrollment_ids).delete_all
      SavingsEntryVersion.where(savings_enrollment_id: enrollment_ids).delete_all
      SavingsPlanVersion.where(savings_enrollment_id: enrollment_ids).delete_all
      SavingsZeroAttestation.where(savings_enrollment_id: enrollment_ids).delete_all
      SavingsEntry.where(id: entry_ids).delete_all
      SavingsEnrollment.where(id: enrollment_ids).delete_all
      tables.each { |table| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER USER") }
    end
  end
end
