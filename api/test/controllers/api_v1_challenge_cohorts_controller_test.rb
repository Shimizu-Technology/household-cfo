require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1ChallengeCohortsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    setup_savings_context
    with_daily_operations { savings_enroll; savings_plan; savings_approve(savings_draft(12345)); daily_check_in("no_spend") }
  end
  teardown { travel_back }

  test "coach roster exposes completion and help metadata without private financial values" do
    get path("participants"), headers: auth(@savings_owner)
    assert_response :success
    row = response.parsed_body.fetch("records").sole
    assert row.dig("check_in", "completed")
    assert_equal @savings_enrollment.id, row["enrollment_id"]
    assert_equal @savings_owner.id, response.parsed_body.dig("actor_scope", "user_id")
    assert_not response.body.match?(/12345|reported_cents|target_cents|no_spend|merchant|feeling|spending_state/)
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get path("participants"), headers: auth(@savings_owner)
    assert_response :success
    assert_nil response.parsed_body.fetch("records").sole.dig("check_in", "completed")
    get "/api/v1/shared_challenges/#{@savings_enrollment.id}/scopes", headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "participant unrelated admin and removed staff cannot inspect the roster or report" do
    admin = User.create!(clerk_id: SecureRandom.uuid, email: "unrelated-#{SecureRandom.hex(4)}@example.com", role: "admin", invitation_status: "accepted")
    [ @savings_user, admin ].each do |actor|
      get path("participants"), headers: auth(actor)
      assert_response :forbidden
      get path("sponsor_exports"), headers: auth(actor)
      assert_response :forbidden
    end
    CoachWorkspaceMembership.where(user: @savings_owner).delete_all
    get path("participants"), headers: auth(@savings_owner)
    assert_response :forbidden
  end

  test "fixed report explicit approval is repeatable suppressed and rejects filters and consent changes" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    input = { checkpoint_day: 30, accepted: true }
    post path("sponsor_exports"), params: input.merge(department: "one person"), headers: auth(@savings_owner), as: :json
    assert_response :unprocessable_entity
    assert_empty ChallengeSponsorExport.all
    2.times do
      post path("sponsor_exports"), params: input, headers: auth(@savings_owner), as: :json
      assert_response :success
      assert response.parsed_body.dig("report", "suppressed")
      assert_empty response.parsed_body.dig("report", "bands")
      assert_not response.body.match?(/enrollment_id|reported_cents|private_provenance|12345/)
    end
    assert_equal 1, ChallengeSponsorExport.count
    id = ChallengeSponsorExport.sole.id
    get path("sponsor_exports/#{id}"), params: { department: "one person" }, headers: auth(@savings_owner)
    assert_response :unprocessable_entity
    get path("sponsor_exports/#{id}.csv"), headers: auth(@savings_owner)
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_not response.body.match?(/enrollment_id|reported_cents|12345/)
    @savings_enrollment.reload.update!(status: "withdrawn")
    get path("sponsor_exports/#{id}"), headers: auth(@savings_owner)
    assert_response :forbidden
    assert_equal 1, ChallengeSponsorExport.count
  end

  test "sharing scope metadata never returns private contents and rechecks expiry" do
    route = "/api/v1/shared_challenges/#{@savings_enrollment.id}/scopes"
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_equal false, response.parsed_body["summary_available"]
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    message = session.chat_messages.create!(role: "user", content: "Synthetic private feelings secret", cohort: @savings_cohort, cohort_release: @savings_release)
    op = HouseholdFinance::Operations::Privacy::ConsentSet.new(@savings_household, user: @savings_user)
    op.execute!(op.prepare(enrollment_id: @savings_enrollment.id, kind: "selected_details", recipient_user_id: @savings_owner.id,
      granted: true, selected_records: [ { record_type: "chat_message", record_id: message.id } ], expires_at: 1.hour.from_now.iso8601,
      policy_version: "challenge_privacy_v1", expected_grant_id: nil, expected_lock_version: 0), source: "manual_ui")
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_equal [ { "record_type" => "chat_message", "record_id" => message.id } ], response.parsed_body["selected_records"]
    assert_not_includes response.body, message.content
    travel 2.hours
    get route, headers: auth(@savings_owner)
    assert_response :success
    assert_empty response.parsed_body["selected_records"]
  end

  private
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def path(suffix) = "/api/v1/challenge_cohorts/#{@savings_cohort.id}/#{suffix}"
end
