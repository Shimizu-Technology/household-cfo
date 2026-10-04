require "test_helper"
require "timeout"
require_relative "../support/savings_daily_test_support"

class SavingsDailyConcurrencyTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport
  self.use_transactional_tests = false

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
  end

  teardown do
    clear_owned_daily_fixture
    travel_back
  end

  test "simultaneous approval retries publish one actual and one immutable purchase version" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
      # A retry sends the identical reviewed locks, even if its worker begins
      # after the winning approval committed and advanced the persisted draft.
      outcomes = concurrently([ true, true ]) { daily_approve(draft, token: "same daily approval") }
      assert outcomes.all? { |value| value.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count(&:replayed?)
      assert_equal 1, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 1, @savings_household.household_transactions.count
      assert_equal 1, SavingsDailyLedger.find_by!(savings_enrollment: @savings_enrollment).sequence
    end
  end

  test "competing corrections publish only one replacement and preserve old canonical facts" do
    with_daily_operations do
      savings_enroll
      first = daily_approve(daily_stage).subject
      drafts = [ daily_stage(3000, purchase: first.savings_daily_purchase), daily_stage(4000, purchase: first.savings_daily_purchase) ]
      outcomes = concurrently(drafts.map(&:id)) { |id| daily_approve(SavingsDailyPurchaseDraft.find(id)) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Runner::Result) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 2, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 2, @savings_household.household_transactions.count
      assert_equal 1, @savings_household.household_transactions.where(status: "confirmed").count
      assert_equal 2500, first.household_transaction.reload.total_amount_cents
      assert_equal "ignored", first.household_transaction.status
    end
  end

  test "simultaneous checkpoint drafts cannot publish competing successors" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      drafts = 2.times.map { checkpoint_stage(30) }
      outcomes = concurrently(drafts.map(&:id)) { |id| checkpoint_approve(SavingsCheckpointDraft.find(id)) }
      assert_equal 1, outcomes.count { |value| value.is_a?(SavingsCheckpointVersion) }
      assert_equal 1, outcomes.count { |value| value.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 1, SavingsCheckpointVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 1, SavingsCheckpoint.where(savings_enrollment: @savings_enrollment).count
    end
  end

  test "cohort hold committed before blocked daily approval leaves no expense or private approved version" do
    with_daily_operations do
      savings_enroll
      draft = daily_stage
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
      assert_raises(ActiveRecord::LockWaitTimeout) { daily_approve(draft) }
      connection.execute("SET lock_timeout = DEFAULT")
      release << true
      holder.value
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { daily_approve(draft) }
      assert_equal 0, SavingsDailyPurchaseVersion.where(savings_enrollment: @savings_enrollment).count
      assert_empty @savings_household.household_transactions
    ensure
      connection&.execute("SET lock_timeout = DEFAULT")
      release << true if holder&.alive?
      holder&.join(10)
    end
  end

  private

  def concurrently(values)
    ready, release = Queue.new, Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield value
        rescue StandardError => error
          error
        end
      end
    end
    Timeout.timeout(10) { values.size.times { ready.pop } }
    values.size.times { release << true }
    threads.each { |thread| thread.join(20) }
    assert threads.none?(&:alive?), "Private daily operations did not finish within the bounded test"
    threads.map(&:value)
  ensure
    values.size.times { release << true }
    threads&.each { |thread| thread.join(1) }
  end

  def clear_owned_daily_fixture
    connection = ActiveRecord::Base.connection
    configured = ENV.fetch("DATABASE_TEST_NAME", "household_cfo_api_test")
    raise "Synthetic cleanup requires the configured test DB" unless Rails.env.test? && connection.select_value("SELECT current_database()") == configured
    daily_tables = %w[savings_daily_ledgers savings_daily_purchases savings_daily_purchase_drafts savings_daily_purchase_versions savings_daily_reflections savings_daily_reflection_versions savings_daily_check_ins savings_daily_check_in_versions savings_checkpoints savings_checkpoint_drafts savings_checkpoint_versions]
    savings_tables = %w[savings_enrollments savings_entries savings_entry_versions savings_plan_versions savings_zero_attestations savings_entry_drafts savings_plan_drafts]
    release_tables = %w[cohorts cohort_release_activation_events cohort_releases cohort_experience_versions cohort_experience_publication_events]
    tables = daily_tables + savings_tables + release_tables
    enrollment_ids = SavingsEnrollment.where(cohort_id: @savings_cohort.id).pluck(:id)
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
      %w[savings_daily_purchases savings_daily_reflections savings_daily_check_ins savings_checkpoints].each do |table|
        connection.execute("UPDATE #{table} SET current_version_id = NULL WHERE savings_enrollment_id IN (#{enrollment_ids.join(',')})") if enrollment_ids.any?
      end
      %w[savings_daily_purchase_drafts savings_checkpoint_drafts savings_checkpoint_versions savings_daily_check_in_versions savings_daily_reflection_versions savings_daily_reflections savings_daily_purchase_versions savings_daily_check_ins savings_checkpoints savings_daily_purchases savings_daily_ledgers].each do |table|
        table.classify.constantize.where(savings_enrollment_id: enrollment_ids).delete_all
      end
      SavingsEnrollment.where(id: enrollment_ids).update_all(current_accepted_plan_version_id: nil)
      SavingsEntry.where(savings_enrollment_id: enrollment_ids).update_all(current_approved_version_id: nil)
      %w[SavingsEntryDraft SavingsPlanDraft SavingsEntryVersion SavingsPlanVersion SavingsZeroAttestation SavingsEntry SavingsEnrollment].each do |name|
        model = name.constantize
        scope = if name == "SavingsEnrollment"
          model.where(id: enrollment_ids)
        elsif name == "SavingsEntryDraft"
          model.where(savings_entry_id: SavingsEntry.where(savings_enrollment_id: enrollment_ids).select(:id))
        else
          model.where(savings_enrollment_id: enrollment_ids)
        end
        scope.delete_all
      end
      @savings_cohort.update_columns(active_cohort_release_id: nil)
      CohortReleaseActivationEvent.where(cohort_id: @savings_cohort.id).delete_all
      CohortRelease.where(cohort_id: @savings_cohort.id).delete_all
      configuration = @savings_cohort.cohort_experience_configuration
      configuration.update_columns(current_published_version_id: nil)
      CohortExperiencePublicationEvent.where(cohort_experience_configuration_id: configuration.id).delete_all
      CohortExperienceVersion.where(cohort_experience_configuration_id: configuration.id).delete_all
      tables.each { |table| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER USER") }
    end
    CohortMembership.where(cohort_id: @savings_cohort.id).delete_all
    CohortExperienceConfiguration.where(cohort_id: @savings_cohort.id).delete_all
    Cohort.where(id: @savings_cohort.id).delete_all
    @savings_household.destroy!
    delete_empty_coach_workspaces_for_users([ @savings_user.id, @savings_owner.id ])
    @savings_user.reload.destroy!
    @savings_owner.reload.destroy!
  end
end
