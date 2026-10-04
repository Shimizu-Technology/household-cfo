require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ChallengeRemindersTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport
  class FakeEmail
    attr_reader :calls
    attr_accessor :verdict, :namespace
    def initialize(idempotent: false, verdict: :delivered)
      @idempotent, @verdict, @calls, @namespace = idempotent, verdict, [], "synthetic_v1"
    end
    def enabled? = true
    def supports_idempotency? = @idempotent
    def idempotency_namespace = namespace
    def deliver(**arguments)
      @calls << arguments
      raise IOError, "Synthetic unknown result" if verdict == :raise
      verdict
    end
  end

  setup do
    @reminder_flags = %w[REMINDERS_EMAIL_ENABLED REMINDERS_SENDER_VERIFIED].index_with { |key| ENV[key] }
    @reminder_flags.each_key { |key| ENV.delete(key) }
    travel_to Time.utc(2026, 11, 1, 8, 0)
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @domain = ChallengeReminders::Domain.new(@savings_household, user: @savings_user)
  end
  teardown do
    travel_back
    @reminder_flags.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "private read defaults in app without any email consent or financial fields" do
    payload = @domain.read(@savings_enrollment.id)
    assert_equal [ true, false ], payload[:preferences].pluck(:enabled)
    assert_equal "Pacific/Guam", payload[:time_zone]
    assert_nil payload[:reminder]
    assert_not payload[:dismissal_is_check_in]
    assert_not payload[:email_delivery_enabled]
    assert_equal 0, ChallengeReminderPreference.count
    assert_equal %i[email_delivery_enabled enrollment_id preferences reminder dismissal_is_check_in time_zone].sort, payload.keys.sort
  end

  test "default recovery delivers one generic local day in app without a queue" do
    2.times { ChallengeReminderRecoveryJob.perform_now }
    reminder = ChallengeReminder.sole
    assert_equal "delivered", reminder.status
    assert_equal "in_app", reminder.channel
    assert_equal Date.new(2026, 11, 1), reminder.local_on
    assert_equal 1, reminder.attempts
    payload = @domain.read(@savings_enrollment.id)
    assert_equal ChallengeReminders::Delivery::GENERIC_MESSAGE[:body], payload[:reminder][:body]
    assert_not payload[:reminder].key?(:amount_cents)
  end

  test "scheduler obeys pinned Guam local time and inclusive personal dates" do
    travel_to Time.utc(2026, 11, 1, 7, 59)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_empty ChallengeReminder.all
    travel_to Time.utc(2026, 11, 1, 8, 0)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal Date.new(2026, 11, 1), ChallengeReminder.sole.local_on
    travel_to Time.utc(2027, 1, 29, 8, 0)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal Date.new(2027, 1, 29), ChallengeReminder.order(:id).last.local_on
    travel_to Time.utc(2027, 1, 30, 8, 0)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal 2, ChallengeReminder.count
  end

  test "quiet hours span midnight and scheduler does not backfill after an outage" do
    set_preference(local_time: "00:00", quiet_start: "21:00", quiet_end: "08:00")
    travel_to Time.utc(2026, 11, 1, 13, 59, 59) # 23:59:59 Guam
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_empty ChallengeReminder.all
    travel_to Time.utc(2026, 11, 1, 14, 0, 0) # Next Guam local day
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_empty ChallengeReminder.all
    travel_to Time.utc(2026, 11, 5, 22, 0, 0)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal Date.new(2026, 11, 6), ChallengeReminder.sole.local_on
  end

  test "Guam midnight yields distinct local dates without UTC duplication" do
    set_preference(local_time: "00:00", quiet_start: "00:00", quiet_end: "00:00")
    travel_to Time.utc(2026, 11, 1, 13, 59, 59)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    travel_to Time.utc(2026, 11, 1, 14, 0, 0)
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal [ Date.new(2026, 11, 1), Date.new(2026, 11, 2) ], ChallengeReminder.order(:local_on).pluck(:local_on)
    assert_equal 2, ChallengeReminder.count
  end

  test "email explicit consent is separate and default adapter never delivers" do
    set_preference(channel: "email")
    ChallengeReminderRecoveryJob.perform_now
    assert_equal [ "in_app" ], ChallengeReminder.pluck(:channel)
    fake = FakeEmail.new
    ChallengeReminders::Scheduler.new(email: fake).schedule(@savings_enrollment.id)
    reminder = ChallengeReminder.find_by!(channel: "email")
    ChallengeReminders::Delivery.new.dispatch(reminder.id)
    assert_equal "cancelled", reminder.reload.status
    assert_equal "channel_disabled", reminder.reason_code
    assert_empty fake.calls
  end

  test "email rechecks consent between claim and dispatch" do
    fake, reminder = scheduled_email
    delivery = ChallengeReminders::Delivery.new(email: fake)
    token = delivery.claim(reminder.id)
    set_preference(channel: "email", enabled: false)
    delivery.deliver_claim(reminder.id, token)
    assert_empty fake.calls
    assert_equal "cancelled", reminder.reload.status
    assert_equal "preference_disabled", reminder.reason_code
  end

  test "role revocation runtime hold and removed membership each block scheduling and dispatch" do
    fake, reminder = scheduled_email
    delivery = ChallengeReminders::Delivery.new(email: fake)
    @savings_cohort.update!(savings_challenge_release_hold: true)
    delivery.dispatch(reminder.id)
    assert_equal "participant_unavailable", reminder.reload.reason_code
    assert_empty fake.calls
    assert_raises(ArgumentError) { set_preference(channel: "email") }
    set_preference(channel: "email", enabled: false)
    @savings_cohort.update!(savings_challenge_release_hold: false)
    @savings_user.update!(role: "coach")
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal 2, ChallengeReminder.count
    @savings_user.update!(role: "participant")
    @savings_membership.destroy!
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    assert_equal 2, ChallengeReminder.count
  end

  test "withdrawal still permits opt out and dismissal but never enables" do
    ChallengeReminderRecoveryJob.perform_now
    @savings_enrollment.update!(status: "withdrawn")
    set_preference(enabled: false)
    assert_raises(ArgumentError) { set_preference(enabled: true) }
    reminder = ChallengeReminder.sole
    execute(HouseholdFinance::Operations::Reminders::Dismiss, { enrollment_id: @savings_enrollment.id, reminder_id: reminder.id, expected_lock_version: reminder.lock_version })
    assert reminder.reload.dismissed_at
    assert_nil @domain.read(@savings_enrollment.id)[:reminder]
    assert_equal 0, SavingsZeroAttestation.count
    assert_equal 0, SavingsEntry.count
  end

  test "competing preference prepared operations conflict and events remain immutable" do
    operation = HouseholdFinance::Operations::Reminders::PreferenceSet.new(@savings_household, user: @savings_user)
    first = operation.prepare(preference_input)
    second = operation.prepare(preference_input(enabled: false))
    event = operation.execute!(first, source: "synthetic_test")
    assert operation.verify_after!(first.predicted_after_snapshot, operation.after_snapshot(event, first))
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation.execute!(second, source: "synthetic_test") }
    assert operation.authorize_replay!(event)
    assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { event.update_columns(approved_values: {}) } }
    @savings_user.update!(role: "coach")
    assert_raises(ChallengePrivacy::Access::Denied) { operation.authorize_replay!(event) }
  end

  test "foreign participant household and notification IDs fail closed" do
    foreign = User.create!(clerk_id: "foreign-reminder", email: "foreign-reminder@example.com", role: "participant", invitation_status: "accepted")
    @savings_household.household_memberships.create!(user: foreign, role: "partner")
    other = ChallengeReminders::Domain.new(@savings_household, user: foreign)
    assert_raises(ActiveRecord::RecordNotFound) { other.read(@savings_enrollment.id) }
    assert_raises(ArgumentError) { @domain.normalize("preference", preference_input.merge(raw_message: "private data")) }
    assert_raises(ArgumentError) { @domain.normalize("preference", preference_input(local_time: "25:01")) }
    assert_raises(ArgumentError) { @domain.normalize("preference", preference_input(enabled: "true")) }
  end

  test "queue admission failure leaves outbox recoverable and does not create activity" do
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    with_override(ChallengeReminderRecoveryJob, :perform_later, -> { raise IOError, "Synthetic queue failure" }) do
      assert_not ChallengeReminders::Delivery.request_dispatch
    end
    assert_equal "pending", ChallengeReminder.sole.status
    ChallengeReminderRecoveryJob.perform_now
    assert_equal "delivered", ChallengeReminder.sole.status
    assert_equal 0, SavingsEntry.count
    assert_equal 0, SavingsZeroAttestation.count
  end

  test "changed quiet hours and local prompt time defer a pending notification" do
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    reminder = ChallengeReminder.sole
    set_preference(local_time: "19:00")
    ChallengeReminders::Delivery.new.dispatch(reminder.id)
    assert_equal "pending", reminder.reload.status
    assert_equal "before_local_time", reminder.reason_code
    travel_to Time.utc(2026, 11, 1, 9, 0)
    set_preference(local_time: "18:00", quiet_start: "18:00", quiet_end: "20:00")
    ChallengeReminders::Delivery.new.dispatch(reminder.id)
    assert_equal "quiet_hours", reminder.reload.reason_code
  end

  test "old pending local day cancels rather than delivering backlog" do
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    travel_to Time.utc(2026, 11, 2, 8, 0)
    ChallengeReminders::Delivery.new.call
    assert_equal "outside_personal_day", ChallengeReminder.sole.reason_code
    ChallengeReminderRecoveryJob.perform_now
    assert_equal [ "cancelled", "delivered" ], ChallengeReminder.order(:id).pluck(:status)
  end

  test "supplied confirmed daily attendance suppresses but reminder results never do" do
    attendance = Object.new
    attendance.define_singleton_method(:completed?) { |**_args| true }
    ChallengeReminders::Scheduler.new(attendance: attendance).schedule(@savings_enrollment.id)
    assert_empty ChallengeReminder.all
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    ChallengeReminders::Delivery.new(attendance: attendance).call
    assert_equal "attendance_confirmed", ChallengeReminder.sole.reason_code
  end

  test "uncertain non idempotent email never blindly retries" do
    fake, reminder = scheduled_email(verdict: :raise)
    delivery = ChallengeReminders::Delivery.new(email: fake)
    2.times { delivery.dispatch(reminder.id) }
    assert_equal 1, fake.calls.length
    assert_equal "unknown", reminder.reload.status
    assert reminder.delivery_uncertain
    assert_equal "delivery_unknown", reminder.reason_code
  end

  test "stable idempotent email retries with exact same identity and generic payload" do
    fake, reminder = scheduled_email(idempotent: true, verdict: :raise)
    delivery = ChallengeReminders::Delivery.new(email: fake)
    delivery.dispatch(reminder.id)
    assert reminder.reload.delivery_uncertain
    assert_equal "pending", reminder.status
    fake.verdict = :delivered
    travel 61.seconds
    delivery.dispatch(reminder.id)
    assert_equal 2, fake.calls.length
    assert_equal 1, fake.calls.pluck(:delivery_key).uniq.length
    assert_equal ChallengeReminders::Delivery::GENERIC_MESSAGE, fake.calls.first[:message]
    assert_equal @savings_user.email, fake.calls.first[:recipient]
    assert_equal "delivered", reminder.reload.status
    assert_not reminder.delivery_uncertain
  end

  test "provider identity changes fail closed and cannot rewrite the pinned namespace" do
    fake, reminder = scheduled_email(idempotent: true, verdict: :raise)
    delivery = ChallengeReminders::Delivery.new(email: fake)
    delivery.dispatch(reminder.id)
    fake.namespace = "different_provider"
    travel 61.seconds
    delivery.dispatch(reminder.id)
    assert_equal "unknown", reminder.reload.status
    assert_equal 1, fake.calls.length
    assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { reminder.update_columns(provider_namespace: "changed") } }
  end

  test "crashed non idempotent email lease becomes unknown without replaying" do
    fake, reminder = scheduled_email
    delivery = ChallengeReminders::Delivery.new(email: fake)
    token = delivery.claim(reminder.id)
    travel 121.seconds
    delivery.recover
    delivery.deliver_claim(reminder.id, token)
    assert_equal "unknown", reminder.reload.status
    assert reminder.delivery_uncertain
    assert_empty fake.calls
  end

  test "crashed in app lease recovers and stale token is fenced" do
    ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
    reminder = ChallengeReminder.sole
    delivery = ChallengeReminders::Delivery.new
    old_token = delivery.claim(reminder.id)
    travel 121.seconds
    delivery.recover
    travel 61.seconds
    token = delivery.claim(reminder.id)
    delivery.deliver_claim(reminder.id, old_token)
    assert_equal "leased", reminder.reload.status
    delivery.deliver_claim(reminder.id, token)
    assert_equal "delivered", reminder.reload.status
    assert_equal 2, reminder.attempts
    assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { reminder.update_columns(status: "pending") } }
  end

  test "known not sent has bounded retry and uncertainty at final attempt stays unknown" do
    fake, reminder = scheduled_email(idempotent: true, verdict: :not_sent)
    delivery = ChallengeReminders::Delivery.new(email: fake)
    4.times { delivery.dispatch(reminder.id); travel 901.seconds }
    fake.verdict = :raise
    delivery.dispatch(reminder.id)
    assert_equal 5, fake.calls.length
    assert_equal "unknown", reminder.reload.status
    assert reminder.delivery_uncertain
    assert_equal 0, SavingsZeroAttestation.count
  end

  test "source lease expiry honors later explicit use and creates cleanup without storage" do
    source = FinancialDocumentImport.create!(household: @savings_household, uploaded_by_user: @savings_user,
      document_kind: "statement", status: "needs_review", filename: "synthetic.csv", content_type: "text/csv", byte_size: 1, s3_key: "synthetic-never-uploaded")
    use = FinancialSourceUse.create!(household: @savings_household, savings_enrollment: @savings_enrollment, participant_user_id: @savings_user.id,
      financial_document_import: source, expires_at: Time.current + 60.seconds, authorized_at: Time.current, disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION)
    partner = User.create!(clerk_id: "lease-partner", email: "lease-partner@example.com", role: "participant", invitation_status: "accepted")
    @savings_household.household_memberships.create!(user: partner, role: "partner")
    member = @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
    enrollment = SavingsEnrollment.create!(@savings_enrollment.attributes.symbolize_keys.slice(:cohort_id, :accepted_cohort_release_id, :accepted_at, :accepted_local_on, :starts_on, :ends_on, :policy_version).merge(
      household: @savings_household, user: partner, accepted_cohort_membership_id: member.id, membership_started_at: member.created_at))
    later_use = FinancialSourceUse.create!(household: @savings_household, savings_enrollment: enrollment, participant_user_id: partner.id,
      financial_document_import: source, expires_at: Time.current + 600.seconds, authorized_at: Time.current, disclosure_version: ChallengePrivacy::SourceRetention::DISCLOSURE_VERSION)
    with_override(S3Service, :delete!, ->(*_arguments) { flunk "Sweep must not call storage" }) do
      ChallengeSourceLeaseExpiryJob.perform_now
      assert_nil source.reload.source_deleted_at
      assert_equal 0, FinancialDocumentSourceCleanup.count
      travel 61.seconds
      ChallengeSourceLeaseExpiryJob.perform_now
      assert_nil source.reload.source_deleted_at
      assert_equal 0, FinancialDocumentSourceCleanup.count
      travel 540.seconds
      2.times { ChallengeSourceLeaseExpiryJob.perform_now }
      assert source.reload.source_deleted_at
      assert use.reload.revoked_at
      assert later_use.reload.revoked_at
      assert_equal 1, FinancialDocumentSourceCleanup.count
      assert_equal "pending", FinancialDocumentSourceCleanup.sole.status
      assert_not ChallengePrivacy::SourceRetention.available?(source)
    end
  end

  test "production email requires operator flag verified sender public root and transport" do
    config = email_config
    assert ChallengeReminders::ProductionEmail.new(env: config).enabled?
    assert_not ChallengeReminders::ProductionEmail.new(env: config).supports_idempotency?
    %w[REMINDERS_EMAIL_ENABLED REMINDERS_SENDER_VERIFIED REMINDERS_FROM_EMAIL SMTP_ADDRESS].each do |key|
      assert_not ChallengeReminders::ProductionEmail.new(env: config.except(key)).enabled?, key
    end
    %w[http://example.com/ https://localhost/ https://192.168.1.10/ https://example.com/private https://example.com/?token=private https://user@example.com/].each do |url|
      assert_not ChallengeReminders::ProductionEmail.new(env: config.merge("REMINDERS_PUBLIC_APP_URL" => url)).enabled?
    end
    assert_not ChallengeReminders::ProductionEmail.new(env: config.merge("REMINDERS_FROM_EMAIL" => "bad\r\nBcc: other@example.com")).enabled?
  end

  test "ActionMailer message is generic plain text and contains only public entry URL" do
    message = ChallengeReminderMailer.daily_check_in(recipient: "synthetic-recipient@example.com", sender: "noreply@example.com",
      public_app_url: "https://example.com/", delivery_key: SecureRandom.uuid).message
    assert_equal [ "synthetic-recipient@example.com" ], message.to
    assert_equal "Your daily check-in", message.subject
    assert_equal "text/plain", message.mime_type
    assert_equal "Open the app when you are ready for your daily check-in.\n\nhttps://example.com/\n", message.body.decoded
    assert_empty message.attachments
    %w[amount merchant feeling statement emotion].each { |private_word| assert_not_includes message.body.decoded, private_word }
    assert_equal 0, ActionMailer::Base.deliveries.length
  end

  test "configured SMTP adapter only uses supplied fake mailer and bounded TLS settings" do
    fake = Class.new do
      class << self
        attr_accessor :smtp_settings, :delivery_method, :received, :deliveries, :perform_deliveries, :raise_delivery_errors
        def daily_check_in(**arguments)
          self.received = arguments
          new
        end
      end
      self.smtp_settings = {}
      self.deliveries = 0
      self.perform_deliveries = true
      def deliver_now = self.class.deliveries += 1
    end
    adapter = ChallengeReminders::ProductionEmail.new(env: email_config, mailer: fake)
    assert_equal :delivered, adapter.deliver(recipient: "synthetic@example.com", delivery_key: SecureRandom.uuid, message: ChallengeReminders::Delivery::GENERIC_MESSAGE)
    assert_equal 1, fake.deliveries
    assert fake.raise_delivery_errors
    fake.perform_deliveries = false
    assert_not adapter.enabled?
    assert_equal "https://example.com/", fake.received[:public_app_url]
    assert_equal 5, fake.smtp_settings[:open_timeout]
    assert_equal 10, fake.smtp_settings[:read_timeout]
    assert fake.smtp_settings[:enable_starttls]
    assert_equal "peer", fake.smtp_settings[:openssl_verify_mode]
    assert_equal :not_sent, adapter.deliver(recipient: "synthetic@example.com", delivery_key: SecureRandom.uuid, message: { amount_cents: 500 })
    assert_equal 1, fake.deliveries
  end

  private
  def email_config
    { "REMINDERS_EMAIL_ENABLED" => "true", "REMINDERS_SENDER_VERIFIED" => "true", "REMINDERS_FROM_EMAIL" => "noreply@example.com",
      "REMINDERS_PUBLIC_APP_URL" => "https://example.com/", "SMTP_ADDRESS" => "smtp.example.com" }
  end
  def with_override(object, method, replacement)
    original = object.method(method)
    object.define_singleton_method(method, replacement)
    yield
  ensure
    object.define_singleton_method(method, original)
  end
  def preference_input(channel: "in_app", enabled: true, local_time: "18:00", quiet_start: "21:00", quiet_end: "08:00")
    pref = ChallengeReminderPreference.find_by(savings_enrollment: @savings_enrollment, channel: channel)
    { enrollment_id: @savings_enrollment.id, channel: channel, enabled: enabled, local_time: local_time, quiet_start: quiet_start,
      quiet_end: quiet_end, policy_version: ChallengeReminderPreference::POLICY_VERSION, expected_preference_id: pref&.id, expected_lock_version: pref&.lock_version || 0 }
  end
  def set_preference(**options) = execute(HouseholdFinance::Operations::Reminders::PreferenceSet, preference_input(**options))
  def execute(type, input)
    operation = type.new(@savings_household, user: @savings_user)
    operation.execute!(operation.prepare(input), source: "synthetic_test")
  end
  def scheduled_email(**options)
    set_preference(channel: "email")
    fake = FakeEmail.new(**options)
    ChallengeReminders::Scheduler.new(email: fake).schedule(@savings_enrollment.id)
    [ fake, ChallengeReminder.find_by!(channel: "email") ]
  end
end
