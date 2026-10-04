require "test_helper"
require_relative "../support/savings_debt_test_support"

class ApiV1SavingsDebtControllerTest < ActionDispatch::IntegrationTest
  include SavingsDebtTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "staging is private pending work and explicit approval supports recovery without full budget" do
    with_savings_runtime do
      savings_enroll
      token = SecureRandom.uuid
      post "#{path}/actions/stage", params: stage_input, headers: headers(key: token), as: :json
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      draft = SavingsDebtDraft.find(response.parsed_body.dig("record", "id"))
      assert_nil draft.savings_debt_card.current_version_id
      get "#{path}/request_status?review_action=stage", headers: headers(key: token)
      assert_response :success
      assert_equal "committed", response.parsed_body["state"]
      assert_equal @savings_cohort.id, response.parsed_body["cohort_id"]
      assert_equal @savings_enrollment.id, response.parsed_body["enrollment_id"]
      assert_equal draft.id, response.parsed_body.dig("record", "id")
      post "#{path}/actions/approve", params: debt_approval_input(draft), headers: headers, as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("record", "terms", "apr_bps")
      get path, headers: headers
      assert_response :success
      assert_equal 30_000, response.parsed_body["known_balance_subtotal_cents"]
      assert_equal false, response.parsed_body["portfolio_complete"]
      assert_nil response.parsed_body["extra_payment_cents"]
      get "#{path}/request_status?review_action=approve", headers: headers
      assert_equal "unknown", response.parsed_body["state"]
      assert_equal true, response.parsed_body["can_retry"]
      assert_equal @savings_cohort.id, response.parsed_body["cohort_id"]
      get "#{path}/source_candidates", headers: headers
      assert_equal @savings_cohort.id, response.parsed_body["cohort_id"]
      assert_equal @savings_enrollment.id, response.parsed_body["enrollment_id"]
    end
  end

  test "unsupported scopes floats boolean zero-knownness and stale approval cannot be injected" do
    with_savings_runtime do
      savings_enroll
      [ { user_id: @savings_user.id }, { cohort_id: @savings_cohort.id }, { current_version_id: 1 }, { approved_at: Time.current.iso8601 }, { reporting_known: true }, { approval_sequence: 100 } ].each do |extra|
        post "#{path}/actions/stage", params: stage_input.merge(extra), headers: headers, as: :json
        assert_response :unprocessable_entity
      end
      post "#{path}/actions/stage", params: stage_input.merge(terms: debt_terms(balance_cents: 1.5)), headers: headers, as: :json
      assert_response :unprocessable_entity
      draft = debt_stage
      post "#{path}/actions/approve", params: debt_approval_input(draft).merge(expected_head_lock_version: 999), headers: headers, as: :json
      assert_response :conflict
      assert_nil draft.reload.approved_version_id
    end
  end

  test "same-household partner coach hold revoked membership and cross-program cannot read another participant card" do
    with_savings_runtime do
      savings_enroll
      original_enrollment = @savings_enrollment
      draft = debt_stage
      partner = User.create!(clerk_id: "debt-partner-#{SecureRandom.hex(8)}", email: "debt-partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
      get path, headers: headers(user: partner)
      assert_response :not_found
      actor = @savings_user
      @savings_user = partner; savings_enroll; @savings_user = actor; @savings_enrollment = original_enrollment
      post "#{path}/actions/approve", params: debt_approval_input(draft), headers: headers(user: partner), as: :json
      assert_response :not_found
      get path, headers: headers(user: @savings_owner)
      assert_not_equal 200, response.status
      @savings_cohort.update!(savings_challenge_release_hold: true)
      get path, headers: headers
      assert_response :forbidden
      @savings_cohort.update!(savings_challenge_release_hold: false)
      @savings_membership.destroy!
      get path, headers: headers
      assert_not_equal 200, response.status
      assert_nil draft.reload.approved_version_id
    end
  end

  test "selected other program and role changed actor cannot recover or read prior private terms" do
    with_savings_runtime do
      savings_enroll
      token = "actor recovery before role change"
      debt_stage(token: token)
      other = Cohort.create!(name: "Other synthetic program", created_by_user: @savings_owner, starts_on: Date.new(2026, 11, 1))
      other.cohort_memberships.create!(user: @savings_user, role: "participant")
      get path, headers: headers.merge("X-Cohort-Id" => other.id.to_s)
      assert_not_equal 200, response.status
      refute_includes response.body, "Synthetic reviewed card"
      @savings_user.update!(role: "coach")
      get "#{path}/request_status?review_action=stage", headers: headers(key: token)
      assert_not_equal 200, response.status
      refute_includes response.body, "Synthetic reviewed card"
      get path, headers: headers
      assert_not_equal 200, response.status
    end
  end

  test "real sealed older V4 release denies new operations and debt reads without changing its bytes" do
    original = CohortReleases::ToolContracts.method(:version_for_experience)
    CohortReleases::ToolContracts.define_singleton_method(:version_for_experience) { |_config| 4 }
    with_savings_runtime do
      savings_enroll
      snapshot = @savings_release.tool_registry_snapshot.deep_dup
      assert_equal 4, @savings_release.tool_registry_version
      get path, headers: headers
      assert_response :forbidden
      post "#{path}/actions/stage", params: stage_input, headers: headers, as: :json
      assert_response :forbidden
      assert_equal snapshot, @savings_release.reload.tool_registry_snapshot
      assert_equal 0, SavingsDebtDraft.count
    end
  ensure
    CohortReleases::ToolContracts.define_singleton_method(:version_for_experience, original)
  end

  test "exact record pagination contains only current participant enrollment with stable cursors" do
    with_savings_runtime do
      savings_enroll
      51.times { debt_stage }
      get "#{path}/records?kind=drafts", headers: headers
      assert_response :success
      ids = response.parsed_body["records"].map { |row| row["id"] }
      assert_equal 50, ids.length
      get "#{path}/records?kind=drafts&cursor=#{response.parsed_body['next_cursor']}", headers: headers
      assert_equal 1, response.parsed_body["records"].length
      refute_includes ids, response.parsed_body["records"].sole["id"]
      get "#{path}/records?kind=unknown", headers: headers
      assert_response :unprocessable_entity
    end
  end

  private
  def path = "/api/v1/savings_challenge/debt"
  def stage_input = { terms: debt_terms, expected_version_id: nil, expected_head_lock_version: 0 }
  def headers(user: @savings_user, key: SecureRandom.uuid)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s, "Idempotency-Key" => key }
  end
end
