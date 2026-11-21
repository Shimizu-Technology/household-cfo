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
      debt = mia([ "Should I pay down my credit card debt or save?" ]).first
      assert_includes debt, "a card payment reduces debt but isn't added to that savings total", debt
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
      debt = mia([ "Should I pay down my credit card debt or save?" ]).first
      assert_includes debt, "extra payments beyond the minimum", debt
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
      assert_equal({ day: 1, length_days: 90, checkpoint_days: [ 30, 60, 90 ], finished: false }, rows.fetch(@savings_user.id).fetch(:challenge))
      assert_equal({ day: 1, length_days: 60, checkpoint_days: [ 20, 40, 60 ], finished: false }, rows.fetch(later_user.id).fetch(:challenge))

      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: { "Authorization" => "Bearer test_token_#{admin.id}" }
      assert_response :success
      # Both schedules: the live one and the one the earlier joiner keeps.
      assert_equal [ 20, 30, 40, 60, 90 ], response.parsed_body.fetch("scheduled_checkpoints").pluck("day")
      assert_nil response.parsed_body.fetch("rules_notice")

      # A group day she does not have is its own band, not a missing result.
      earlier = SavingsEnrollment.find_by!(user: @savings_user)
      snapshot = ChallengePrivacy::ApprovedCheckpointAdapter.new.snapshot(earlier, checkpoint_day: 20, cutoff_on: @savings_cohort.starts_on + 19)
      assert_equal "other_schedule", snapshot.fetch(:band)
    end
  end

  test "reports keep every schedule people joined under, seal in any order and keep a saved day reachable" do
    with_savings_runtime do
      earlier = savings_enroll
      publish_savings_challenge_rules(SHORT)
      later_user, later_household = second_participant
      later = savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: true,
        expected_acceptance_digest: savings_offer_digest(user: later_user) }, user: later_user, household: later_household).subject
      owner = { "Authorization" => "Bearer test_token_#{@savings_owner.id}" }
      seal = lambda do |day|
        post "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", params: { checkpoint_day: day, accepted: true }, headers: owner, as: :json
        response
      end

      # After the group's Day 90 (Jan 29), every day on either schedule can be saved.
      travel_to Time.find_zone!("Pacific/Guam").local(2027, 2, 1, 12) do
        assert_equal [ 20, 30, 40, 60, 90 ], ChallengePrivacy::SponsorExports.reportable_days(@savings_cohort)
        assert_predicate seal.call(30), :successful?
        # Day 20 comes after Day 30 was saved; it was refused before (increasing order only).
        assert_predicate seal.call(20), :successful?, response.body
        # Day 90 is the earlier joiner's final report; the live schedule no longer has it.
        assert_predicate seal.call(90), :successful?, response.body
        assert_equal 3, ChallengeSponsorExport.where(cohort: @savings_cohort).count
        day_thirty = ChallengeSponsorExport.find_by!(cohort: @savings_cohort, checkpoint_day: 30)
        assert_equal day_thirty.id, seal.call(30).parsed_body.fetch("export_id")
        assert_equal 422, seal.call(45).status
        assert_equal "Choose Day 20, 30, 40, 60 or 90", response.parsed_body.fetch("errors").first

        # Each person is placed on her own days: the earlier joiner on Day 90, the later one on Day 20.
        adapter = ChallengePrivacy::ApprovedCheckpointAdapter.new
        cohort_day = ->(day) { @savings_cohort.starts_on + day - 1 }
        refute_equal "other_schedule", adapter.snapshot(earlier.reload, checkpoint_day: 90, cutoff_on: cohort_day.call(90)).fetch(:band)
        assert_equal "other_schedule", adapter.snapshot(later.reload, checkpoint_day: 90, cutoff_on: cohort_day.call(90)).fetch(:band)
        assert_equal "other_schedule", adapter.snapshot(earlier, checkpoint_day: 20, cutoff_on: cohort_day.call(20)).fetch(:band)
        refute_equal "other_schedule", adapter.snapshot(later, checkpoint_day: 20, cutoff_on: cohort_day.call(20)).fetch(:band)

        # A day saved under a schedule nobody is on any more is still listed and can be reopened.
        exporter = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @savings_owner)
        provenance = exporter.send(:current_provenance).merge(observations: [])
        old_report = { "checkpoint_day" => 45, "bands" => [], "suppressed" => true }
        ChallengeSponsorExport.create!(cohort: @savings_cohort, checkpoint_day: 45, policy_version: ChallengePrivacy::SponsorExports::POLICY_VERSION,
          approved_by_user: @savings_owner, resolved_cutoff_on: cohort_day.call(45), private_provenance: provenance, report: old_report,
          digest: "b" * 64, created_at: Time.current)
        get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: owner
        assert_includes response.parsed_body.fetch("scheduled_checkpoints").pluck("day"), 45
        assert_equal old_report, seal.call(45).parsed_body.fetch("report")
      end
    end
  end

  test "before she joins, Mia uses the rules her group would give her" do
    with_savings_runtime do
      publish_savings_challenge_rules({ "length_days" => 60, "checkpoints" => "thirds", "suggested_goal_cents" => 100_000, "counts" => "savings" })
      assert_nil SavingsEnrollment.find_by(user: @savings_user)
      captured = []
      SavingsChallenge::Narrator.define_singleton_method(:new) { |**options| super(**options).tap { |narrator| captured << narrator } }
      begin
        mia([ "What should I know about the savings challenge before I start?" ])
      ensure
        SavingsChallenge::Narrator.singleton_class.send(:remove_method, :new)
      end
      narrator = captured.sole
      contract = narrator.send(:narrator_contract)
      assert_includes contract, "This is the 60-day savings challenge. The recommended $1,000 is total new money reserved"
      assert_includes contract, "Check-ins are on Day 20, 40 and 60."
      refute_includes contract, "90-day"
      # The monthly-obligation boundary checks the group's own suggested amount.
      assert narrator.send(:challenge_boundary_violation?, "Plan on $1,000 each month for this.")

      rules = SavingsChallenge::Rules.for_participant(user: @savings_user)
      assert_equal [ 60, [ 20, 40, 60 ], 100_000 ], [ rules.length_days, rules.checkpoint_days, rules.suggested_goal_cents ]
      answerer = HouseholdFinance::MiaCoachAnswerer.new(@savings_household, "Could I save $1,000 for the challenge?", user: @savings_user, ensure_plan: false)
      assert_equal "60-day", answerer.send(:challenge_rules).label
      coach = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: nil, message: "Can you suggest a goal?")
      assert_equal 100_000, coach.send(:rules).suggested_goal_cents
    end
  end

  test "a day number in passing is not a progress question" do
    with_savings_runtime do
      savings_enroll
      passing, asked = mia([ "I'll call the bank on day 30 about my account", "What happens on day 30?" ])
      refute_includes passing, "Day 30: Dec 14", passing
      assert_includes asked, "Day 30: Dec 14", asked
      assert SavingsChallenge::ChatTurn.checkpoint_question?("Is my day 20 check-in ready?", [ 20, 40, 60 ])
      refute SavingsChallenge::ChatTurn.checkpoint_question?("Is my day 20 check-in ready?", [ 30, 60, 90 ])
      refute SavingsChallenge::ChatTurn.checkpoint_question?("I'll call the bank on day 30", [ 30, 60, 90 ])
    end
  end

  test "debt and card answers say what counts under her rule" do
    with_savings_runtime do
      publish_savings_challenge_rules(SHORT)
      enrollment = savings_enroll
      no_debt = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: enrollment, message: "I don't have any debt").send(:debt_answer)
      assert_includes no_debt, "and so do extra payments on a card or loan beyond the minimum"
      refute_includes no_debt, "Only approved new money"
      coach = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: enrollment, message: "Which card should I pay first?")
      assert_includes coach.send(:card_payment_sentence), "Extra payments beyond the minimum count toward your challenge total"
      default = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: SavingsEnrollment.new(challenge_length_days: 90, checkpoint_days: [ 30, 60, 90 ], suggested_goal_cents: 50_000, goal_counts: "savings"), message: "I don't have any debt")
      assert_includes default.send(:debt_answer), "Only approved new money you set aside, minus withdrawals, counts toward the challenge."
      assert_equal "Card payments lower debt but don't count toward your savings total.", default.send(:card_payment_sentence)
    end
  end

  test "the Go live preview says when people are already running the challenge" do
    with_savings_runtime do
      preview = lambda do
        configuration = @savings_cohort.cohort_experience_configuration.reload
        post "/api/v1/admin/cohorts/#{@savings_cohort.id}/experience_configuration/preview",
          params: { experience_configuration: { draft_revision: configuration.draft_revision } }, headers: { "Authorization" => "Bearer test_token_#{@savings_owner.id}" }, as: :json
        assert_response :success
        response.parsed_body.dig("preview", "challenge_running")
      end
      assert_equal false, preview.call
      savings_enroll
      assert_equal true, preview.call
    end
  end

  test "the roster says Finished once her last day has passed" do
    with_savings_runtime do
      publish_savings_challenge_rules(SHORT)
      enrollment = savings_enroll
      assert_equal({ day: 60, length_days: 60, checkpoint_days: [ 20, 40, 60 ], finished: false }, ChallengePrivacy::SharedReader.challenge_calendar(enrollment, enrollment.ends_on))
      assert_equal({ day: 60, length_days: 60, checkpoint_days: [ 20, 40, 60 ], finished: true }, ChallengePrivacy::SharedReader.challenge_calendar(enrollment, enrollment.ends_on + 1))
    end
  end

  test "coach screens say when a group's challenge settings can't be read" do
    with_savings_runtime do
      release = @savings_cohort.active_cohort_release
      broken = release.dup.tap { |copy| copy.experience_snapshot = [ "not a sealed experience" ] }
      rules, readable = SavingsChallenge::Rules.read_release(broken)
      assert_equal [ SavingsChallenge::Rules.default, false ], [ rules, readable ]
      assert_equal [ SavingsChallenge::Rules.default, true ], SavingsChallenge::Rules.read_release(nil)
      assert_equal true, SavingsChallenge::Rules.read_release(release).last
      assert_includes SavingsChallenge::Rules.unreadable_notice, "couldn't be read, so the standard 90-day rules"
      assert_nil SavingsChallenge::LaunchControl.new(cohort: @savings_cohort).status.fetch(:rules_notice)
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
