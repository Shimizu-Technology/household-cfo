require "timeout"
require "active_support/testing/time_helpers"
require_relative "../support/savings_challenge_test_support"

database = ActiveRecord::Base.connection_db_config.database
unless Rails.env.test? && database == ENV.fetch("PRIVACY_CONCURRENCY_DISPOSABLE_DATABASE") && database.end_with?("_test")
  raise "This script requires its exact explicitly authorized disposable test database"
end

class PrivacyConcurrencyFixture
  include SavingsChallengeTestSupport
  include ActiveSupport::Testing::TimeHelpers
  attr_reader :household, :participant, :cohort, :coach, :enrollment
  def build
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @household, @participant, @cohort, @coach, @enrollment = @savings_household, @savings_user, @savings_cohort, @savings_owner, @savings_enrollment
  end
  def add_participant
    user = User.create!(clerk_id: SecureRandom.uuid, email: "privacy-race-#{SecureRandom.hex(8)}@example.com", role: "participant")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    member = cohort.cohort_memberships.create!(user: user, role: "participant")
    SavingsEnrollment.create!(household: household, user: user, cohort: cohort, accepted_cohort_release: @savings_release,
      accepted_cohort_membership_id: member.id, membership_started_at: member.created_at, accepted_at: Time.current,
      accepted_local_on: enrollment.accepted_local_on, starts_on: enrollment.starts_on, ends_on: enrollment.ends_on, policy_version: "1")
  end
end

class PrivacyConcurrencyAdapter < ChallengePrivacy::SponsorExports::CheckpointAdapter
  attr_reader :calls
  def initialize = (@calls, @mutex = 0, Mutex.new)
  def snapshot(enrollment, checkpoint_day:, cutoff_on:)
    @mutex.synchronize { @calls += 1 }
    { enrollment_id: enrollment.id, checkpoint_id: enrollment.id, checkpoint_version: 1,
      cutoff_on: cutoff_on.iso8601, digest: "c" * 64, band: "at_target" }
  end
end

def simultaneous(count)
  ready, release, output = Queue.new, Queue.new, Queue.new
  threads = count.times.map do |index|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        release.pop
        output << yield(index)
      rescue StandardError => error
        output << error
      end
    end
  end
  Timeout.timeout(30) do
    count.times { ready.pop }
    count.times { release << true }
    threads.each(&:join)
  end
  count.times.map { output.pop }
ensure
  count.times { release << true } if release
  threads&.each { |thread| thread.join(1) }
end

fixture = PrivacyConcurrencyFixture.new
fixture.build
input = { enrollment_id: fixture.enrollment.id, kind: "coach_summary", recipient_user_id: fixture.coach.id, granted: true,
  selected_records: [], expires_at: nil, policy_version: "challenge_privacy_v1", expected_grant_id: nil, expected_lock_version: 0 }
prepared = 2.times.map { HouseholdFinance::Operations::Privacy::ConsentSet.new(fixture.household, user: fixture.participant).prepare(input) }
outcomes = simultaneous(2) do |index|
  operation = HouseholdFinance::Operations::Privacy::ConsentSet.new(Household.find(fixture.household.id), user: User.find(fixture.participant.id))
  operation.execute!(prepared[index], source: "manual_ui")
  "approved"
rescue HouseholdFinance::Operations::Base::StaleOperation
  "stale_blocked"
end
raise "Concurrent consent choices were not serialized" unless outcomes.sort == %w[approved stale_blocked]
raise "Concurrent consent duplicated history" unless ChallengePrivacyEvent.where(savings_enrollment: fixture.enrollment, action: "consent").count == 1

participants = [ fixture.enrollment ] + 4.times.map { fixture.add_participant }
participants.each do |enrollment|
  operation = HouseholdFinance::Operations::Privacy::ConsentSet.new(enrollment.household, user: enrollment.user)
  values = input.merge(enrollment_id: enrollment.id, kind: "sponsor_aggregate", recipient_user_id: nil)
  operation.execute!(operation.prepare(values), source: "manual_ui")
end
adapter = PrivacyConcurrencyAdapter.new
reports = simultaneous(2) do
  ChallengePrivacy::SponsorExports.new(Cohort.find(fixture.cohort.id), user: User.find(fixture.coach.id), adapter: adapter)
    .approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-15")
end
raise "Fixed export approval failed" if reports.any? { |value| value.is_a?(Exception) }
raise "Concurrent fixed exports diverged" unless reports.uniq.length == 1 && ChallengeSponsorExport.where(cohort: fixture.cohort).count == 1 && adapter.calls == 5

grant = ChallengePrivacyGrant.find_by!(savings_enrollment: fixture.enrollment, kind: "sponsor_aggregate")
entered, release, output = Queue.new, Queue.new, Queue.new
revoker = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    ApplicationRecord.transaction do
      Household.lock.find(fixture.household.id)
      current = ChallengePrivacyGrant.find(grant.id)
      current.update!(granted: false)
      entered << true
      release.pop
    end
  end
end
Timeout.timeout(30) { entered.pop }
reader = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    ChallengePrivacy::SponsorExports.new(Cohort.find(fixture.cohort.id), user: User.find(fixture.coach.id)).read(ChallengeSponsorExport.where(cohort: fixture.cohort).sole.id)
    output << "unexpected_read"
  rescue ChallengePrivacy::Access::Denied
    output << "revocation_blocked"
  rescue StandardError => error
    output << error
  end
end
release << true
Timeout.timeout(30) { [ revoker, reader ].each(&:join) }
raise "Concurrent revocation was not enforced" unless output.pop == "revocation_blocked"
puts JSON.generate(check: "challenge_privacy_concurrency", consent_outcomes: outcomes.sort,
  fixed_exports: 1, checkpoint_adapter_reads: adapter.calls, revoked_export: "blocked", alternate_reports_created: 0)
fixture.travel_back
