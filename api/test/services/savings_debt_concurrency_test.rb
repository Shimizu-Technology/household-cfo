require "test_helper"
require "timeout"
require_relative "../support/savings_debt_test_support"

class SavingsDebtConcurrencyTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport
  self.use_transactional_tests = false
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown do
    cleanup_owned_debt_fixture
    travel_back
  end

  test "two approvals of pending corrections serialize and exactly one advances the approved head" do
    with_savings_runtime do
      savings_enroll
      first = debt_approve(debt_stage)
      drafts = [ 20_000, 25_000 ].map { |amount| debt_stage(debt_terms(balance_cents: amount), card: first.savings_debt_card) }
      outcomes = concurrently(drafts.map { |draft| debt_approval_input(draft) }) { |input| savings_run("debt.approve", input) }
      assert_equal 1, outcomes.count { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count { |row| row.is_a?(HouseholdFinance::Operations::Base::StaleOperation) }
      assert_equal 2, first.savings_debt_card.savings_debt_versions.count
      assert_equal 1, SavingsDebtDraft.where(id: drafts.map(&:id), status: "pending").count
      assert_equal 30_000, first.reload.terms["balance_cents"]
    end
  end

  test "same approval request concurrently commits one immutable version and safely replays the other" do
    with_savings_runtime do
      savings_enroll
      draft = debt_stage
      input = debt_approval_input(draft)
      outcomes = concurrently([ input, input ]) { |row| savings_run("debt.approve", row, token: "same private card review") }
      assert outcomes.all? { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count(&:replayed?)
      assert_equal 1, SavingsDebtVersion.where(savings_enrollment: @savings_enrollment).count
    end
  end

  test "two identities cannot concurrently claim the same canonical liability within an enrollment" do
    with_savings_runtime do
      savings_enroll
      identity, = debt_source
      drafts = 2.times.map { debt_stage(debt_terms(as_of_on: "2026-10-31"), source: debt_mapping(identity)) }
      outcomes = concurrently(drafts.map { |draft| debt_approval_input(draft) }) { |input| savings_run("debt.approve", input) }
      assert_equal 1, outcomes.count { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count { |row| row.is_a?(ArgumentError) }
      assert_equal 1, SavingsDebtCard.where(savings_enrollment: @savings_enrollment).where.not(source_tracked_account_id: nil).count
    end
  end

  test "status recovery returns bounded in-flight metadata during a competing household transaction" do
    with_savings_runtime do
      savings_enroll
      ready, release = Queue.new, Queue.new
      locker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ApplicationRecord.transaction do
            Household.lock.find(@savings_household.id)
            ready << true
            release.pop
          end
        end
      end
      Timeout.timeout(10) { ready.pop }
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.get "/api/v1/savings_challenge/debt/request_status?review_action=stage", headers: {
        "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s, "Idempotency-Key" => "recover bounded unknown" }
      assert_equal 202, session.response.status
      assert_equal "in_flight", session.response.parsed_body["state"]
      assert_equal({ "user_id" => @savings_user.id, "household_id" => @savings_household.id }, session.response.parsed_body["actor_scope"])
      assert_equal "private, no-store", session.response.headers["Cache-Control"]
      assert_equal 0, SavingsDebtDraft.where(savings_enrollment: @savings_enrollment).count
    ensure
      release << true
      locker&.join(10)
      assert !locker&.alive?, "Status recovery locker must finish"
    end
  end

  private
  def concurrently(inputs)
    ready, start = Queue.new, Queue.new
    threads = inputs.map do |input|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          start.pop
          yield input
        rescue StandardError => error
          error
        end
      end
    end
    Timeout.timeout(10) { inputs.size.times { ready.pop } }
    inputs.size.times { start << true }
    threads.each { |thread| thread.join(20) }
    assert threads.none?(&:alive?), "Card approvals exceeded the bounded test wait"
    threads.map(&:value)
  ensure
    inputs.size.times { start << true }
    threads&.each { |thread| thread.join(1) }
  end

  def cleanup_owned_debt_fixture
    @savings_user = @evidence_original_user if @evidence_original_user
    connection = ApplicationRecord.connection
    raise "Cleanup requires the owned disposable DB" unless Rails.env.test? && connection.select_value("SELECT current_database()") == ENV.fetch("DATABASE_TEST_NAME")
    hh = @savings_household.id
    enrollment_ids = SavingsEnrollment.where(household_id: hh).pluck(:id)
    evidence_ids = SavingsEvidenceVersion.where(savings_enrollment_id: enrollment_ids).pluck(:id)
    source_tables = %w[source_economic_memberships source_economic_group_versions source_economic_groups source_review_drafts source_projection_revisions source_revision_approvals source_review_versions source_review_heads source_account_identity_versions source_account_review_heads source_tracked_accounts financial_source_evidences financial_source_events financial_source_accounts financial_extraction_revisions]
    savings_tables = %w[savings_evidence_allocations savings_evidence_versions savings_evidence_capacities savings_enrollments savings_entries savings_entry_versions savings_entry_drafts savings_plan_versions savings_plan_drafts savings_zero_attestations]
    release_tables = %w[cohorts cohort_release_activation_events cohort_releases cohort_experience_versions cohort_experience_publication_events]
    debt_tables = %w[savings_debt_cards savings_debt_drafts savings_debt_versions]
    tables = debt_tables + source_tables + savings_tables + release_tables
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
      card_ids = SavingsDebtCard.where(savings_enrollment_id: enrollment_ids).pluck(:id)
      SavingsDebtCard.where(id: card_ids).update_all(current_version_id: nil)
      SavingsDebtDraft.where(savings_debt_card_id: card_ids).delete_all
      SavingsDebtVersion.where(savings_debt_card_id: card_ids).delete_all
      SavingsDebtCard.where(id: card_ids).delete_all
      SavingsEvidenceAllocation.where(savings_enrollment_id: enrollment_ids).update_all(current_version_id: nil)
      SavingsEvidenceCapacity.where(savings_evidence_version_id: evidence_ids).delete_all
      SavingsEvidenceVersion.where(savings_enrollment_id: enrollment_ids).delete_all
      SavingsEvidenceAllocation.where(savings_enrollment_id: enrollment_ids).delete_all
      %w[source_economic_groups source_review_heads source_account_review_heads].each { |table| connection.execute("UPDATE #{table} SET approved_version_id=NULL WHERE household_id=#{hh}") }
      source_tables.each { |table| connection.execute("DELETE FROM #{table} WHERE household_id=#{hh}") }
      SavingsEnrollment.where(id: enrollment_ids).update_all(current_accepted_plan_version_id: nil)
      SavingsEntry.where(savings_enrollment_id: enrollment_ids).update_all(current_approved_version_id: nil)
      SavingsEntryDraft.where(savings_entry_id: SavingsEntry.where(savings_enrollment_id: enrollment_ids).select(:id)).delete_all
      %w[SavingsPlanDraft SavingsZeroAttestation SavingsEntryVersion SavingsPlanVersion SavingsEntry].each { |name| name.constantize.where(savings_enrollment_id: enrollment_ids).delete_all }
      SavingsEnrollment.where(id: enrollment_ids).delete_all
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
    @evidence_partner&.reload&.destroy!
  end
end
