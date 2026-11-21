require "test_helper"
require_relative "../support/savings_daily_test_support"

# The challenge's length, check-in days, suggested goal and what counts are program
# settings. Each enrollment keeps the rules it started with.
class SavingsChallengeRulesTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport

  SHORT = { "length_days" => 60, "checkpoints" => "thirds", "suggested_goal_cents" => 30_000, "counts" => "savings_and_debt" }.freeze

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end

  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "the default program gives 90 days, Day 30, 60 and 90, a $500 suggestion and savings only" do
    with_savings_runtime do
      get "/api/v1/savings_challenge", headers: headers
      assert_response :success
      offer = response.parsed_body.fetch("offer")
      assert_equal 50_000, response.parsed_body.fetch("suggested_target_cents")
      assert_equal [ 90, [ 30, 60, 90 ], 50_000, "savings" ], offer.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      assert_equal "2027-02-12", offer.fetch("personal_ends_on")

      enrollment = savings_enroll
      assert_equal [ 90, [ 30, 60, 90 ], 50_000, "savings" ], enrollment.attributes.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      assert_equal enrollment.starts_on + 89, enrollment.ends_on
      get "/api/v1/savings_challenge", headers: headers
      calendar = response.parsed_body.fetch("calendar")
      assert_equal 90, calendar.fetch("length_days")
      assert_equal %w[30 60 90], calendar.fetch("checkpoints").keys
      assert_equal 90, response.parsed_body.dig("timeline", "days").length
      assert_equal 50_000, response.parsed_body.fetch("suggested_target_cents")

      savings_plan
      # Extra debt payments are tracked alongside, not counted.
      savings_approve(savings_draft(12_000, funding: "extra_debt_payment"))
      projection = savings_projection
      assert_equal false, projection[:reporting_known]
      assert_equal 1, projection[:excluded_entry_count]
      assert_equal 12_000, SavingsChallenge::Projection.extra_debt_payment_cents(enrollment.reload)

      answers = mia([ "Can you suggest a goal for me?", "How much savings progress do I have?", "How am I doing on my checkpoints?" ])
      assert_includes answers[0], "$500"
      assert_includes answers[0], "90 days"
      refute_includes answers[0], "extra payments"
      assert_includes answers[1], "90-day challenge"
      assert_includes answers[1], "Your $120 in extra debt payments is tracked alongside, not in the goal."
      assert_includes answers[2], "Day 30: Dec 14; Day 60: Jan 13; Day 90: Feb 12"
    end
  end

  test "a changed program gives new joiners its length, check-in days, suggested goal and what counts" do
    with_savings_runtime do
      publish_savings_challenge_rules(SHORT)
      get "/api/v1/savings_challenge", headers: headers
      offer = response.parsed_body.fetch("offer")
      assert_equal [ 60, [ 20, 40, 60 ], 30_000, "savings_and_debt" ], offer.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      assert_equal 30_000, response.parsed_body.fetch("suggested_target_cents")
      assert_equal "2027-01-13", offer.fetch("personal_ends_on")

      enrollment = savings_enroll
      assert_equal [ 60, [ 20, 40, 60 ], 30_000, "savings_and_debt" ], enrollment.attributes.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      assert_equal Date.new(2027, 1, 13), enrollment.ends_on
      get "/api/v1/savings_challenge", headers: headers
      calendar = response.parsed_body.fetch("calendar")
      assert_equal [ 60, [ 20, 40, 60 ] ], calendar.values_at("length_days", "checkpoint_days")
      assert_equal({ "20" => "2026-12-04", "40" => "2026-12-24", "60" => "2027-01-13" }, calendar.fetch("checkpoints"))
      assert_equal 60, response.parsed_body.dig("timeline", "days").length

      # Extra debt payments count toward this program's goal.
      savings_plan(30_000)
      savings_approve(savings_draft(10_000))
      savings_approve(savings_draft(20_000, funding: "extra_debt_payment"))
      projection = savings_projection
      assert_equal 30_000, projection[:reported_cents]
      assert_equal true, projection[:achieved]
      error = assert_raises(ArgumentError) { savings_run("zero.attest", { cutoff_on: "2026-11-15", known_zero: true, expected_enrollment_lock_version: enrollment.reload.lock_version }) }
      assert_match(/already establish/, error.message)

      answers = mia([ "Can you suggest a goal for me?", "How much savings progress do I have?", "How am I doing on my checkpoints?", "I can save $25 a week for my challenge goal" ])
      assert_includes answers[0], "$300"
      assert_includes answers[0], "60 days"
      assert_includes answers[0], "so do extra payments on a card or loan beyond the minimum"
      assert_includes answers[1], "60-day challenge"
      assert_includes answers[1], "That includes $200 in extra debt payments."
      assert_includes answers[2], "Day 20: Dec 4; Day 40: Dec 24; Day 60: Jan 13"
      assert_includes answers[3], "$25 × 60 ÷ 7 = $214.29"
    end
  end

  test "a running enrollment keeps the rules it started with after the program changes" do
    with_daily_operations do
      earlier = savings_enroll
      publish_savings_challenge_rules(SHORT.merge("checkpoints" => [ 15, 45, 60 ]))
      later_user, later_household = second_participant
      later = savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: true,
        expected_acceptance_digest: savings_offer_digest(user: later_user) }, user: later_user, household: later_household).subject

      assert_equal [ 60, [ 15, 45, 60 ], 30_000, "savings_and_debt" ], later.attributes.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      earlier.reload
      assert_equal [ 90, [ 30, 60, 90 ], 50_000, "savings" ], earlier.attributes.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      assert_equal earlier.starts_on + 89, earlier.ends_on

      get "/api/v1/savings_challenge", headers: headers
      assert_equal %w[30 60 90], response.parsed_body.dig("calendar", "checkpoints").keys
      assert_equal 90, response.parsed_body.dig("timeline", "days").length
      assert_equal 50_000, response.parsed_body.fetch("suggested_target_cents")
      get "/api/v1/savings_challenge", headers: headers(user: later_user)
      assert_equal %w[15 45 60], response.parsed_body.dig("calendar", "checkpoints").keys

      # What counts still follows her original rules.
      @savings_enrollment = earlier
      savings_plan
      savings_approve(savings_draft(12_000, funding: "extra_debt_payment"))
      assert_equal false, savings_projection[:reporting_known]
      assert_includes mia([ "How much savings progress do I have?" ]).first, "90-day challenge"

      # Her check-in days are her own; the database refuses to rewrite them.
      travel_to Time.find_zone!("Pacific/Guam").local(2027, 1, 20, 12) do
        error = assert_raises(ArgumentError) { savings_run("checkpoint.stage", checkpoint_input(15)) }
        assert_equal "Choose Day 30, 60 or 90", error.message
        assert_equal 30, savings_run("checkpoint.stage", checkpoint_input(30)).subject.savings_checkpoint.milestone_day
      end
      [ { challenge_length_days: 60, ends_on: earlier.starts_on + 59 }, { goal_counts: "savings_and_debt" }, { suggested_goal_cents: 30_000 } ].each do |change|
        error = assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { SavingsEnrollment.where(id: earlier.id).update_all(change) } }
        assert_match(/identity is frozen/, error.message)
      end
      assert_equal "savings", earlier.reload.goal_counts
    end
  end

  test "the coach sees each person's own calendar and the group's check-in days in reports" do
    with_savings_runtime do
      savings_enroll
      publish_savings_challenge_rules(SHORT)
      later_user, later_household = second_participant
      savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: true,
        expected_acceptance_digest: savings_offer_digest(user: later_user) }, user: later_user, household: later_household)
      admin = User.create!(clerk_id: "clerk_rules_admin_#{SecureRandom.hex(4)}", email: "rules-admin-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")

      roster = ChallengePrivacy::CoachDailyRoster.new(@savings_cohort.reload, user: admin).call
      assert_equal({ length_days: 60, checkpoint_days: [ 20, 40, 60 ] }, roster.fetch(:challenge))
      rows = roster.fetch(:records).index_by { |row| row.dig(:participant, :id) }
      assert_equal({ day: 1, length_days: 90, checkpoint_days: [ 30, 60, 90 ] }, rows.fetch(@savings_user.id).fetch(:challenge))
      assert_equal({ day: 1, length_days: 60, checkpoint_days: [ 20, 40, 60 ] }, rows.fetch(later_user.id).fetch(:challenge))

      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: { "Authorization" => "Bearer test_token_#{admin.id}" }
      assert_response :success
      assert_equal [ 20, 40, 60 ], response.parsed_body.fetch("scheduled_checkpoints").pluck("day")

      # A group day she does not have is its own band, not a missing result.
      earlier = SavingsEnrollment.find_by!(user: @savings_user)
      snapshot = ChallengePrivacy::ApprovedCheckpointAdapter.new.snapshot(earlier, checkpoint_day: 20, cutoff_on: @savings_cohort.starts_on + 19)
      assert_equal "other_schedule", snapshot.fetch(:band)
    end
  end

  test "reminders stop after a shorter challenge's last day" do
    with_savings_runtime do
      publish_savings_challenge_rules(SHORT)
      enrollment = savings_enroll
      last = Time.find_zone!("Pacific/Guam").local(2027, 1, 13, 18)
      eligibility = ChallengeReminders::Eligibility.new(attendance: ChallengeReminders::Eligibility::NoAttendanceSuppression.new)
      preference = ChallengeReminderPreference.new(ChallengeReminderPreference.defaults("in_app"))
      assert_nil eligibility.reason(enrollment.reload, preference, at: last)
      assert_equal "outside_personal_day", eligibility.reason(enrollment, preference, at: last + 1.day)
    end
  end

  private

  def headers(user: @savings_user, key: SecureRandom.uuid)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s, "Idempotency-Key" => key }
  end

  def mia(messages)
    messages.each_with_index.map do |message, index|
      post "/api/v1/mia/messages", params: { message: message, request_id: "rules-#{SecureRandom.hex(3)}-#{index}" }, headers: headers.except("Idempotency-Key"), as: :json
      assert_response :created
      response.parsed_body.dig("assistant_message", "content")
    end
  end

  def second_participant
    user = User.create!(clerk_id: "clerk_rules_#{SecureRandom.hex(6)}", email: "rules-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    CohortMembership.create!(cohort: @savings_cohort, user: user, role: "participant")
    [ user, household ]
  end

  def checkpoint_input(day)
    { milestone_day: day, expected_version_id: nil, expected_head_lock_version: 0, reason: "" }
  end
end
