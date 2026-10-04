require "timeout"
require "active_support/testing/time_helpers"
require_relative "../support/savings_challenge_test_support"

database = ActiveRecord::Base.connection_db_config.database
unless Rails.env.test? && database == ENV.fetch("REMINDER_CONCURRENCY_DISPOSABLE_DATABASE") && database.end_with?("_test")
  raise "This script requires its exact explicitly authorized disposable database"
end

class ReminderConcurrencyFixture
  include SavingsChallengeTestSupport
  include ActiveSupport::Testing::TimeHelpers
  attr_reader :household, :participant, :enrollment
  def build
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 18)
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @household, @participant, @enrollment = @savings_household, @savings_user, @savings_enrollment
  end
end

class ReminderConcurrencyEmail
  attr_reader :calls
  def initialize = (@calls, @mutex = [], Mutex.new)
  def enabled? = true
  def supports_idempotency? = true
  def idempotency_namespace = "synthetic_concurrency_v1"
  def deliver(**arguments)
    @mutex.synchronize { @calls << arguments.fetch(:delivery_key) }
    :delivered
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
  values = count.times.map { output.pop }
  raise "Concurrent reminder work failed: #{values.find { |value| value.is_a?(Exception) }&.class}" if values.any? { |value| value.is_a?(Exception) }
  values
ensure
  count.times { release << true } if release
  threads&.each { |thread| thread.join(1) }
end

def await_database_lock(application_name)
  Timeout.timeout(10) do
    loop do
      waiting = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND application_name = #{ActiveRecord::Base.connection.quote(application_name)} AND wait_event_type = 'Lock')")
      end
      break if waiting
      sleep 0.02
    end
  end
end

fixture = ReminderConcurrencyFixture.new
fixture.build
disabled = ChallengeReminders::Delivery::DisabledEmail.new
simultaneous(2) { ChallengeReminders::Scheduler.new(email: disabled).schedule(fixture.enrollment.id); "scheduled" }
notification = ChallengeReminder.where(savings_enrollment: fixture.enrollment).sole
simultaneous(2) { ChallengeReminders::Delivery.new(email: disabled).dispatch(notification.id); "dispatched" }
raise "Concurrent scheduler or dispatch duplicated local day" unless notification.reload.status == "delivered" && notification.attempts == 1 && ChallengeReminder.where(savings_enrollment: fixture.enrollment).count == 1

input = { enrollment_id: fixture.enrollment.id, channel: "email", enabled: true, local_time: "18:00", quiet_start: "21:00", quiet_end: "08:00",
  policy_version: ChallengeReminderPreference::POLICY_VERSION, expected_preference_id: nil, expected_lock_version: 0 }
operation = HouseholdFinance::Operations::Reminders::PreferenceSet.new(fixture.household, user: fixture.participant)
operation.execute!(operation.prepare(input), source: "synthetic_test")
email = ReminderConcurrencyEmail.new
simultaneous(2) { ChallengeReminders::Scheduler.new(email: email).schedule(fixture.enrollment.id); "scheduled" }
notification = ChallengeReminder.find_by!(savings_enrollment: fixture.enrollment, channel: "email")
simultaneous(2) { ChallengeReminders::Delivery.new(email: email).dispatch(notification.id); "dispatched" }
raise "Concurrent leases duplicated fake email" unless email.calls.length == 1 && notification.reload.attempts == 1

fixture.travel 1.day
ChallengeReminders::Scheduler.new(email: email).schedule(fixture.enrollment.id)
notification = ChallengeReminder.find_by!(savings_enrollment: fixture.enrollment, channel: "email", local_on: fixture.enrollment.local_today)
delivery = ChallengeReminders::Delivery.new(email: email)
token = delivery.claim(notification.id)
preference = ChallengeReminderPreference.find_by!(savings_enrollment: fixture.enrollment, channel: "email")
input = input.merge(enabled: false, expected_preference_id: preference.id, expected_lock_version: preference.lock_version)
prepared = operation.prepare(input)
entered, release = Queue.new, Queue.new
revoker = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    ApplicationRecord.transaction do
      household = Household.lock.find(fixture.household.id)
      actor = User.find(fixture.participant.id)
      HouseholdFinance::Operations::Reminders::PreferenceSet.new(household, user: actor).execute!(prepared, source: "synthetic_test")
      entered << true
      release.pop
    end
  end
end
Timeout.timeout(30) { entered.pop }
worker = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do |connection|
    connection.execute("SET application_name = 's09_revoked_lease'")
    ChallengeReminders::Delivery.new(email: email).deliver_claim(notification.id, token)
  end
end
await_database_lock("s09_revoked_lease")
release << true
Timeout.timeout(30) { [ revoker, worker ].each(&:join) }
raise "Committed opt-out failed to stop leased send" unless notification.reload.status == "cancelled" && email.calls.length == 1

fixture.travel 1.day
ChallengeReminders::Scheduler.new(email: disabled).schedule(fixture.enrollment.id)
notification = ChallengeReminder.find_by!(savings_enrollment: fixture.enrollment, channel: "in_app", local_on: fixture.enrollment.local_today)
token = ChallengeReminders::Delivery.new(email: disabled).claim(notification.id)
fixture.travel 121.seconds
simultaneous(2) { ChallengeReminders::Delivery.new(email: disabled).recover; "recovered" }
fixture.travel 61.seconds
simultaneous(2) { ChallengeReminders::Delivery.new(email: disabled).dispatch(notification.id); "dispatched" }
ChallengeReminders::Delivery.new(email: disabled).deliver_claim(notification.id, token)
raise "Recovery or stale lease duplicated in-app effect" unless notification.reload.status == "delivered" && notification.attempts == 2

source = FinancialDocumentImport.create!(household: fixture.household, uploaded_by_user: fixture.participant,
  document_kind: "statement", status: "needs_review", filename: "synthetic-retention.csv", content_type: "text/csv", byte_size: 1, s3_key: "synthetic-never-uploaded")
use = FinancialSourceUse.create!(household: fixture.household, savings_enrollment: fixture.enrollment, participant_user_id: fixture.participant.id,
  financial_document_import: source, expires_at: Time.current - 1.second, authorized_at: Time.current - 1.day, disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION)
expiry = (fixture.enrollment.ends_on.in_time_zone(fixture.enrollment.time_zone).end_of_day + 30.days).iso8601
operation = HouseholdFinance::Operations::Privacy::SourceUseAuthorize.new(fixture.household, user: fixture.participant)
prepared = operation.prepare(enrollment_id: fixture.enrollment.id, document_import_id: source.id,
  disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION, expected_expires_at: expiry, expected_use_id: use.id, expected_lock_version: use.lock_version)
entered, release, sweep_started = Queue.new, Queue.new, Queue.new
authorizer = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    ApplicationRecord.transaction do
      household = Household.lock.find(fixture.household.id)
      operation = HouseholdFinance::Operations::Privacy::SourceUseAuthorize.new(household, user: User.find(fixture.participant.id))
      operation.execute!(prepared, source: "synthetic_test")
      entered << true
      release.pop
    end
  end
end
Timeout.timeout(30) { entered.pop }
sweeper = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do |connection|
    connection.execute("SET application_name = 's09_source_sweeper'")
    sweep_started << true
    ChallengeReminders::SourceLeaseSweep.new.call
  end
end
Timeout.timeout(30) { sweep_started.pop }
await_database_lock("s09_source_sweeper")
release << true
Timeout.timeout(30) { [ authorizer, sweeper ].each(&:join) }
raise "Expiry discarded a newly authorized explicit later use" unless source.reload.source_deleted_at.nil? && FinancialDocumentSourceCleanup.where(financial_document_import_id: source.id).empty? && use.reload.expires_at > Time.current

puts JSON.generate(check: "challenge_reminder_concurrency", local_day_rows: "unique", concurrent_fake_email_effects: email.calls.length,
  revoked_lease: "blocked", recovered_in_app_attempts: notification.attempts, stale_lease: "fenced", concurrent_source_extension: "retained", outbound_calls: 0)
fixture.travel_back
