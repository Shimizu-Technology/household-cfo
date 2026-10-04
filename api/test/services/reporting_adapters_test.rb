require "test_helper"
require_relative "../support/savings_daily_test_support"

class ReportingAdaptersTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
  end
  teardown { travel_back }

  test "approved classifier pins target and sequence while pending corrections cannot replace approved facts" do
    with_daily_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(50_000))
      at_day(30)
      version = checkpoint_approve(checkpoint_stage(30))
      first = observation(30)
      assert_equal "at_target", first[:band]
      assert_equal version.version_number, first[:checkpoint_version]
      savings_approve(savings_draft(100, entry: entry.savings_entry))
      savings_plan(20_000)
      assert_equal first, observation(30)
      pending = checkpoint_stage(30)
      assert_equal first, observation(30)
      corrected = checkpoint_approve(pending)
      assert_equal "below_target", observation(30)[:band]
      assert_equal 2, corrected.version_number
      assert_not_equal first[:digest], observation(30)[:digest]
    end
  end

  test "known zero is below target while unknown day ninety remains unknown ahead of final pending" do
    with_daily_operations do
      savings_enroll
      savings_plan
      at_day(30)
      savings_zero(on: @savings_enrollment.local_today)
      checkpoint_approve(checkpoint_stage(30))
      assert_equal "below_target", observation(30)[:band]
      at_day(90)
      checkpoint_approve(checkpoint_stage(90))
      assert_equal "unknown", observation(90)[:band]
      savings_zero(on: @savings_enrollment.local_today)
      checkpoint_approve(checkpoint_stage(90))
      assert_equal "final_pending", observation(90)[:band]
      checkpoint_approve(checkpoint_stage(90, final_confirmation_accepted: true))
      assert_equal "below_target", observation(90)[:band]
    end
  end

  test "missing late withdrawn sentinels preserve explicit unapproved identity and fixed scheduled cutoff" do
    with_daily_operations do
      savings_enroll
      at_day(30)
      missing = observation(30)
      assert_equal "unknown", missing[:band]
      assert_nil missing[:checkpoint_version]
      assert_equal "unapproved:#{@savings_enrollment.id}:30", missing[:checkpoint_id]
      assert_equal missing, observation(30)
      assert_raises(ChallengePrivacy::Access::Denied) { adapter.snapshot(@savings_enrollment, checkpoint_day: 30, cutoff_on: Date.new(2026, 11, 29)) }
      travel_to Date.new(2026, 11, 2).in_time_zone("Pacific/Guam").noon
      @savings_user = User.create!(clerk_id: SecureRandom.uuid, email: "late-#{SecureRandom.hex(8)}@example.com", role: "participant")
      @savings_household = HouseholdFinance::WorkspaceResolver.new(@savings_user).household
      @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
      savings_enroll
      at_day(30)
      assert_equal "late_window", observation(30)[:band]
      assert_empty SavingsCheckpoint.all
      @savings_enrollment.update!(status: "withdrawn")
      assert_equal "withdrawn", observation(30)[:band]
    end
  end

  test "thirty real participant approvals yield private immutable provenance coarse bands and failclosed revocation" do
    with_daily_operations do
      participants = []
      30.times do |index|
        travel_to Date.new(2026, 11, index.between?(20, 24) ? 2 : 1).in_time_zone("Pacific/Guam").noon
        if index.positive?
          @savings_user = User.create!(clerk_id: SecureRandom.uuid, email: "adapter-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
          @savings_household = HouseholdFinance::WorkspaceResolver.new(@savings_user).household
          @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
        end
        savings_enroll
        savings_plan(index.between?(10, 14) ? 30_000 : (index.between?(15, 19) ? nil : 50_000))
        savings_approve(savings_draft(50_000)) if index.between?(5, 9)
        sponsor_consent
        participants << @savings_enrollment
      end
      at_day(90)
      participants.each_with_index do |enrollment, index|
        select_participant(enrollment)
        checkpoint_approve(checkpoint_stage(90)) if index < 20
        enrollment.update!(status: "withdrawn") if index >= 25
      end
      service = exporter
      report = service.approve(checkpoint_day: 90, resolved_cutoff_on: "2027-01-29")
      assert_not report["suppressed"]
      assert_equal %w[unknown final_pending custom_target no_target late_window withdrawn].sort, report["bands"].pluck("band").sort
      assert_equal [ "5-9" ], report["bands"].pluck("count_range").uniq
      assert_equal "30-34", report["active_consent_count_range"]
      record = ChallengeSponsorExport.sole
      observations = record.private_provenance.fetch("observations")
      assert_equal 30, observations.pluck("checkpoint_id").uniq.length
      assert_equal 10, observations.count { |row| row["checkpoint_version"].nil? }
      assert_match(/absent target bands do not establish known savings/, report["qualification"])
      assert_not report.to_json.match?(/enrollment_id|checkpoint_id|version_id|reported_cents|merchant|reflection/)
      assert_not service.csv(record.id).match?(/unapproved:|enrollment_id|checkpoint_id|reported_cents/)
      select_participant(participants[5])
      checkpoint_approve(checkpoint_stage(90, final_confirmation_accepted: true))
      assert_equal "at_target", observation(90)[:band]
      assert_equal report, service.approve(checkpoint_day: 90, resolved_cutoff_on: "2027-01-29")
      grant = ChallengePrivacyGrant.find_by!(savings_enrollment: participants.first, kind: "sponsor_aggregate")
      select_participant(participants.first)
      sponsor_consent(granted: false, expected_grant_id: grant.id, expected_lock_version: grant.lock_version)
      assert_raises(ChallengePrivacy::Access::Denied) { service.read(record.id) }
      assert_raises(ChallengePrivacy::Access::Denied) { service.approve(checkpoint_day: 90, resolved_cutoff_on: "2027-01-29") }
      assert_equal 1, ChallengeSponsorExport.count
    end
  end

  test "holds runtime loss and sealed calendar drift fail closed" do
    with_daily_operations do
      savings_enroll
      sponsor_consent
      at_day(30)
      exporter.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-30")
      record = ChallengeSponsorExport.sole
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(ChallengePrivacy::Access::Denied) { exporter.read(record.id) }
      @savings_cohort.update!(savings_challenge_release_hold: false, active_cohort_release: nil)
      assert_raises(ChallengePrivacy::Access::Denied) { exporter.read(record.id) }
      @savings_cohort.update!(starts_on: Date.new(2026, 11, 2))
      at_day(60)
      assert_raises(ChallengePrivacy::Access::Denied) { observation(60, cutoff: Date.new(2026, 12, 31)) }
    end
  end

  test "production validates scheduled cutoff even with no consented observations and rejects fake approved sentinels" do
    with_daily_operations do
      savings_enroll
      at_day(30)
      assert_raises(ChallengePrivacy::Access::Denied) { exporter.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-29") }
      assert_empty ChallengeSponsorExport.all
      sponsor_consent
      fake = Object.new
      fake.define_singleton_method(:snapshot) do |enrollment, checkpoint_day:, cutoff_on:|
        { enrollment_id: enrollment.id, checkpoint_id: "unapproved:#{enrollment.id}:#{checkpoint_day}", checkpoint_version: nil,
          cutoff_on: cutoff_on.iso8601, digest: "a" * 64, band: "at_target" }
      end
      service = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @savings_owner, adapter: fake)
      assert_raises(ChallengePrivacy::Access::Denied) { service.approve(checkpoint_day: 30, resolved_cutoff_on: "2026-11-30") }
      assert_empty ChallengeSponsorExport.all
    end
  end

  test "invalid frozen checkpoint release pins are rejected rather than classified unknown" do
    with_daily_operations do
      savings_enroll
      at_day(30)
      checkpoint_approve(checkpoint_stage(30))
      head = SavingsCheckpoint.find_by!(savings_enrollment: @savings_enrollment, milestone_day: 30)
      version = head.current_version
      version.snapshot = version.snapshot.merge("accepted_cohort_release_id" => -1)
      head.define_singleton_method(:current_version) { version }
      with_return(SavingsCheckpoint, :find_by, head) { assert_raises(ChallengePrivacy::Access::Denied) { observation(30) } }
    end
  end

  test "attendance requires approved spending or no spend and rejects unknown purchase reflection and stale canonical facts" do
    with_daily_operations do
      savings_enroll
      assert_not attended?
      draft = daily_stage
      assert_not attended?
      purchase = daily_approve(draft).subject.savings_daily_purchase
      daily_reflection(purchase)
      assert_not attended?
      daily_check_in("unknown")
      assert_not attended?
      daily_check_in("spending")
      assert attended?
      purchase.reload.current_version.household_transaction.update!(merchant: "Changed independently")
      assert_not attended?
      travel_to Date.new(2026, 11, 2).in_time_zone("Pacific/Guam").noon
      daily_check_in("no_spend")
      assert attended?
      assert_raises(ArgumentError) { daily_approve(daily_stage) }
      projection = { check_in_version_id: SavingsDailyCheckIn.find_by!(savings_enrollment: @savings_enrollment, local_on: @savings_enrollment.local_today).current_version_id,
        canonical_links_changed: false, no_spend_discrepancy: true }
      reader = Object.new
      reader.define_singleton_method(:call) { projection }
      with_return(SavingsChallenge::Daily::DayProjection, :new, reader) { assert_not attended?, "Contradictory no-spend must not suppress" }
    end
  end

  test "actual check ins suppress delivery scheduler recovery while holds and withdrawal fail closed" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").change(hour: 18)
      ChallengeReminders::Scheduler.new.schedule(@savings_enrollment.id)
      reminder = ChallengeReminder.sole
      daily_check_in("no_spend")
      ChallengeReminders::Delivery.new.dispatch(reminder.id)
      assert_equal "cancelled", reminder.reload.status
      assert_equal "attendance_confirmed", reminder.reason_code
      travel_to Date.new(2026, 11, 2).in_time_zone("Pacific/Guam").change(hour: 18)
      daily_check_in("spending")
      ChallengeReminderRecoveryJob.perform_now
      assert_equal 1, ChallengeReminder.count
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_not attended?
      @savings_cohort.update!(savings_challenge_release_hold: false)
      @savings_enrollment.update!(status: "withdrawn")
      assert_not attended?
    end
  end

  private
  def with_return(receiver, method, value)
    original = receiver.method(method)
    receiver.define_singleton_method(method) { |*_args, **_kwargs| value }
    yield
  ensure
    receiver.define_singleton_method(method, original)
  end
  def adapter = ChallengePrivacy::ApprovedCheckpointAdapter.new
  def exporter = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @savings_owner)
  def at_day(day) = travel_to((Date.new(2026, 11, 1) + day - 1).in_time_zone("Pacific/Guam").change(hour: 18))
  def observation(day, cutoff: Date.new(2026, 11, 1) + day - 1) = adapter.snapshot(@savings_enrollment.reload, checkpoint_day: day, cutoff_on: cutoff)
  def attended? = ChallengeReminders::Attendance.new.completed?(enrollment: @savings_enrollment, local_on: @savings_enrollment.local_today)
  def select_participant(enrollment)
    @savings_enrollment, @savings_user, @savings_household = enrollment.reload, enrollment.user, enrollment.household
  end
  def sponsor_consent(**extra)
    op = HouseholdFinance::Operations::Privacy::ConsentSet.new(@savings_household, user: @savings_user)
    prepared = op.prepare({ enrollment_id: @savings_enrollment.id, kind: "sponsor_aggregate", recipient_user_id: nil,
      granted: true, selected_records: [], expires_at: nil, policy_version: "challenge_privacy_v1",
      expected_grant_id: nil, expected_lock_version: 0 }.merge(extra))
    op.execute!(prepared, source: "manual_ui")
  end
end
