require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1ChallengeRemindersControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 19)
    setup_savings_context
    with_savings_runtime { savings_enroll }
  end
  teardown { travel_back }

  test "default private reminders and reviewed opt out do not create attendance or financial records" do
    get path, headers: auth
    assert_response :success
    data = response.parsed_body
    assert data.fetch("preferences").find { |pref| pref["channel"] == "in_app" }.fetch("enabled")
    refute data.fetch("preferences").find { |pref| pref["channel"] == "email" }.fetch("enabled")
    refute data.fetch("email_delivery_enabled")
    assert_nil data.fetch("reminder")
    assert_includes response.headers["Cache-Control"], "no-store"
    input = preference
    2.times do
      post "#{path}/preference", params: input, headers: auth("opt-out"), as: :json
      assert_response :success
      assert_equal %w[actor_scope event replayed], response.parsed_body.keys.sort
    end
    assert response.parsed_body.fetch("replayed")
    assert_equal 1, ChallengeReminderEvent.where(savings_enrollment: @savings_enrollment).count
    get "#{path}/request_status", params: { reminder_action: "preference" }, headers: auth("opt-out")
    assert_response :success
    assert_equal "committed", response.parsed_body.fetch("state")
    get "#{path}/request_status", params: { reminder_action: "dismiss" }, headers: auth("opt-out")
    assert_response :conflict
    assert_empty SavingsDailyCheckInVersion.where(savings_enrollment: @savings_enrollment)
    assert_empty SavingsEntryVersion.where(savings_enrollment: @savings_enrollment)
    execution = @savings_household.household_operation_executions.where(operation_key: "reminder.preference.set").sole
    assert_empty execution.normalized_input
    assert_empty execution.after_snapshot
  end

  test "self controls and disabling remain possible during hold without granting financial reads" do
    @savings_cohort.update!(savings_challenge_release_hold: true)
    @savings_membership.destroy!
    get "/api/v1/savings_challenge/private_controls", headers: auth
    assert_response :success
    record = response.parsed_body.fetch("records").sole
    assert_equal @savings_enrollment.id, record.fetch("id")
    assert_equal %w[cohort_id ends_on id program_name starts_on status time_zone], record.keys.sort
    get path, headers: auth
    assert_response :success
    post "#{path}/preference", params: preference, headers: auth("held-opt-out"), as: :json
    assert_response :success
    post "#{path}/preference", params: preference.merge(enabled: true), headers: auth("held-opt-in"), as: :json
    assert_response :forbidden
    @savings_user.update!(role: "admin")
    get "/api/v1/savings_challenge/private_controls", headers: auth
    assert_response :forbidden
    get path, headers: auth
    assert_response :forbidden
    get "#{path}/request_status", params: { reminder_action: "preference" }, headers: auth("held-opt-out")
    assert_response :forbidden
  end

  private
  def path = "/api/v1/savings_challenge/#{@savings_enrollment.id}/reminders"
  def auth(key = nil)
    { "Authorization" => "Bearer test_token_#{@savings_user.id}" }.tap { |headers| headers["Idempotency-Key"] = key if key }
  end
  def preference
    { enrollment_id: @savings_enrollment.id, channel: "in_app", enabled: false, local_time: "18:00", quiet_start: "21:00", quiet_end: "08:00",
      policy_version: "generic_daily_reminder_v1", expected_preference_id: nil, expected_lock_version: 0 }
  end
end
