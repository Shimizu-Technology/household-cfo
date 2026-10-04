require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1ChallengePrivacyControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll; savings_plan; savings_approve(savings_draft(200)) }
  end
  teardown { travel_back }

  test "private consent approval and recovery preserve actor and separate coach scope" do
    get participant_path, headers: auth(@savings_user)
    assert_response :success
    assert_empty response.parsed_body.fetch("grants")
    assert_includes response.headers["Cache-Control"], "no-store"
    get shared_path("basic"), headers: auth(@savings_owner)
    assert_response :success
    refute response.parsed_body.key?("projection")
    get shared_path("summary"), headers: auth(@savings_owner)
    assert_response :forbidden
    input = consent
    2.times do
      post "#{participant_path}/consent", params: input, headers: auth(@savings_user).merge("Idempotency-Key" => "consent-approval"), as: :json
      assert_response :success
      assert_equal %w[event replayed], response.parsed_body.keys.sort
    end
    assert_equal 1, ChallengePrivacyEvent.where(savings_enrollment: @savings_enrollment).count
    get "#{participant_path}/request_status", params: { privacy_action: "consent" }, headers: auth(@savings_user).merge("Idempotency-Key" => "consent-approval")
    assert_response :success
    assert_equal "committed", response.parsed_body.fetch("state")
    assert_equal %w[action id subject_id subject_type], response.parsed_body.fetch("event").keys.sort
    get shared_path("summary"), headers: auth(@savings_owner)
    assert_response :success
    assert_equal 200, response.parsed_body.dig("projection", "reported_cents")
    assert_not_includes response.body, "merchant"
    grant = ChallengePrivacyGrant.where(savings_enrollment: @savings_enrollment).sole
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get shared_path("summary"), headers: auth(@savings_owner)
    assert_response :forbidden
    get shared_path("basic"), headers: auth(@savings_owner)
    assert_response :success
    post "#{participant_path}/consent", params: input.merge(granted: false, expected_grant_id: grant.id, expected_lock_version: grant.lock_version),
      headers: auth(@savings_user).merge("Idempotency-Key" => "consent-revoke"), as: :json
    assert_response :success
    get shared_path("summary"), headers: auth(@savings_owner)
    assert_response :forbidden
    @savings_household.household_operation_executions.where(operation_key: "privacy.consent.set").each do |execution|
      assert_empty execution.normalized_input
      assert_empty execution.after_snapshot
    end
  end

  test "selected chat grant returns exactly one reviewed message and loses access on revoke" do
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    selected = session.chat_messages.create!(role: "user", content: "Selected synthetic request", cohort: @savings_cohort, cohort_release: @savings_release)
    other = session.chat_messages.create!(role: "user", content: "Unselected synthetic secret", cohort: @savings_cohort, cohort_release: @savings_release)
    foreign_user = User.create!(clerk_id: SecureRandom.uuid, email: "foreign-#{SecureRandom.hex(4)}@example.com", invitation_status: "accepted", role: "participant")
    foreign_session = ChatSession.create!(household: @savings_household, user: foreign_user)
    foreign_message = foreign_session.chat_messages.create!(role: "user", content: "Other participant private message")
    get "#{participant_path}/selection_candidates", params: { record_type: "chat_message" }, headers: auth(@savings_user)
    assert_response :success
    assert_equal [ selected.id, other.id ], response.parsed_body.fetch("records").pluck("record_id")
    assert_not_includes response.body, foreign_message.content
    assert response.parsed_body.fetch("records").all? { |record| record["shares_entire_record"] }
    input = consent.merge(kind: "selected_details", selected_records: [ { record_type: "chat_message", record_id: selected.id } ], expires_at: 1.hour.from_now.iso8601)
    post "#{participant_path}/consent", params: input, headers: auth(@savings_user).merge("Idempotency-Key" => "selected-approval"), as: :json
    assert_response :success
    get shared_path("selected"), params: { record_type: "chat_message", record_id: selected.id }, headers: auth(@savings_owner)
    assert_response :success
    assert_equal selected.content, response.parsed_body.dig("record", "content")
    assert_not_includes response.body, other.content
    get shared_path("selected"), params: { record_type: "chat_message", record_id: other.id }, headers: auth(@savings_owner)
    assert_response :forbidden
    @savings_owner.update!(role: "participant")
    get shared_path("selected"), params: { record_type: "chat_message", record_id: selected.id }, headers: auth(@savings_owner)
    assert_response :forbidden
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get "#{participant_path}/selection_candidates", params: { record_type: "chat_message" }, headers: auth(@savings_user)
    assert_response :forbidden
  end

  private
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def participant_path = "/api/v1/savings_challenge/#{@savings_enrollment.id}/privacy"
  def shared_path(action) = "/api/v1/shared_challenges/#{@savings_enrollment.id}/#{action}"
  def consent
    { enrollment_id: @savings_enrollment.id, kind: "coach_summary", recipient_user_id: @savings_owner.id, granted: true,
      selected_records: [], expires_at: nil, policy_version: "challenge_privacy_v1", expected_grant_id: nil, expected_lock_version: 0 }
  end
end
