require "test_helper"
require "timeout"
require_relative "../support/owned_test_database"
require_relative "../support/savings_evidence_test_support"

class SavingsEvidenceConcurrencyTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport
  self.use_transactional_tests = false

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end

  teardown do
    cleanup_owned_evidence_fixture
    travel_back
  end

  test "competing approvals on different entries share one capacity and one wins" do
    with_evidence_operations do
      savings_enroll
      entries = 2.times.map { savings_approve(savings_draft(10_000)) }
      source, = evidence_source(10_000)
      inputs = entries.map { |entry| evidence_input(entry, [ evidence_proof(source, amount: 6_000) ]) }
      outcomes = concurrently(inputs) { |input| savings_run("evidence.attach", input) }
      assert_equal 1, outcomes.count { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count { |row| row.is_a?(ArgumentError) }
      assert_equal 1, SavingsEvidenceVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 6_000, savings_projection[:evidence_supported_cents]
      assert_equal 20_000, savings_projection[:reported_cents]
    end
  end

  test "identical concurrent retries publish one version and one replay" do
    with_evidence_operations do
      savings_enroll
      entry = savings_approve(savings_draft(10_000))
      source, = evidence_source(10_000)
      input = evidence_input(entry, [ evidence_proof(source, amount: 5_000) ])
      outcomes = concurrently([ input, input ]) { |row| savings_run("evidence.attach", row, token: "same evidence retry") }
      assert outcomes.all? { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count(&:replayed?)
      assert_equal 1, SavingsEvidenceVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 5_000, savings_projection[:evidence_supported_cents]
    end
  end

  test "SQL concurrent publishing cannot bypass global capacity or duplicate approved sequences" do
    with_evidence_operations do
      savings_enroll
      entries = 2.times.map { savings_approve(savings_draft(10_000)) }
      source, = evidence_source(10_000)
      proof = SavingsChallenge::EvidenceProof.new(@savings_enrollment).resolve(evidence_proof(source, amount: 6_000))
      outcomes = concurrently(entries.map(&:id)) do |entry_id|
        ApplicationRecord.transaction do
          Household.lock.find(@savings_household.id)
          enrollment = SavingsEnrollment.lock.find(@savings_enrollment.id)
          head = SavingsEvidenceAllocation.create!(household: @savings_household, savings_enrollment: enrollment, savings_entry_version_id: entry_id)
          version = head.savings_evidence_versions.create!(savings_enrollment: enrollment, approved_by_user: @savings_user, approval_sequence: enrollment.advance_approval_sequence!, version_number: 1,
            state: "attached", supported_cents: 6_000, proof_snapshot: [ proof ], participant_ownership_accepted: true, new_money_reservation_accepted: true,
            digest: "a" * 64, reason: "Synthetic SQL invariant test", approved_at: Time.current)
          binding = proof.fetch("bindings").sole
          version.savings_evidence_capacities.create!(financial_source_event_id: binding.fetch("event_id"), source_review_version_id: source.id, reserved_cents: 6_000, capacity_cents: 10_000)
          head.update!(current_version: version)
          version
        end
      end
      assert_equal 1, outcomes.count { |row| row.is_a?(SavingsEvidenceVersion) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count { |row| row.is_a?(ActiveRecord::StatementInvalid) }
      assert_equal 6_000, savings_projection[:evidence_supported_cents]
    end
  end

  test "partner enrollments compete for one household movement across independent enrollment locks" do
    with_evidence_operations do
      savings_enroll
      original = @savings_enrollment
      owner = @savings_user
      @evidence_original_user = owner
      first = savings_approve(savings_draft(10_000))
      source, = evidence_source(10_000)
      @evidence_partner = User.create!(clerk_id: "evidence-concurrent-#{SecureRandom.hex(8)}", email: "evidence-concurrent-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: @evidence_partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: @evidence_partner, role: "participant")
      @savings_user = @evidence_partner
      savings_enroll
      second = savings_approve(savings_draft(10_000))
      inputs = [ [ owner, evidence_input(first, [ evidence_proof(source, amount: 6_000) ]) ],
        [ @evidence_partner, evidence_input(second, [ evidence_proof(source, amount: 6_000) ]) ] ]
      outcomes = concurrently(inputs) { |actor, input| savings_run("evidence.attach", input, user: actor) }
      assert_equal 1, outcomes.count { |row| row.is_a?(HouseholdFinance::Operations::Runner::Result) }, outcomes.map(&:inspect).join("\n")
      assert_equal 1, outcomes.count { |row| row.is_a?(ArgumentError) }
      projections = [ original, @savings_enrollment ].map { |enrollment| SavingsChallenge::Projection.new(enrollment.reload).call }
      assert_equal 6_000, projections.sum { |projection| projection[:evidence_supported_cents] }
      @savings_user = owner
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
    assert threads.none?(&:alive?), "Evidence approvals exceeded the bounded test wait"
    threads.map(&:value)
  ensure
    inputs.size.times { start << true }
    threads&.each { |thread| thread.join(1) }
  end

  def cleanup_owned_evidence_fixture
    @savings_user = @evidence_original_user if @evidence_original_user
    connection = ApplicationRecord.connection
    OwnedTestDatabase.assert!(connection: connection)
    hh = @savings_household.id
    enrollment_ids = SavingsEnrollment.where(household_id: hh).pluck(:id)
    evidence_ids = SavingsEvidenceVersion.where(savings_enrollment_id: enrollment_ids).pluck(:id)
    source_tables = %w[source_economic_memberships source_economic_group_versions source_economic_groups source_review_drafts source_projection_revisions source_revision_approvals source_review_versions source_review_heads source_account_identity_versions source_account_review_heads source_tracked_accounts financial_source_evidences financial_source_events financial_source_accounts financial_extraction_revisions]
    savings_tables = %w[savings_evidence_allocations savings_evidence_versions savings_evidence_capacities savings_enrollments savings_entries savings_entry_versions savings_entry_drafts savings_plan_versions savings_plan_drafts savings_zero_attestations]
    release_tables = %w[cohorts cohort_release_activation_events cohort_releases cohort_experience_versions cohort_experience_publication_events]
    tables = source_tables + savings_tables + release_tables
    ApplicationRecord.transaction do
      tables.each { |table| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER USER") }
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
