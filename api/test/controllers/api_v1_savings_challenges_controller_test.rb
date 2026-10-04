require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1SavingsChallengesControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
  end

  teardown { travel_back }

  test "current legacy runtime fails closed and a selected participant with future savings runtime can explicitly join" do
    get path, headers: headers
    assert_response :forbidden
    assert_equal "savings_challenge_unavailable", response.parsed_body["code"]
    with_savings_runtime do
      get path, headers: headers
      assert_response :success
      assert_nil response.parsed_body["projection"]
      assert_equal 50_000, response.parsed_body["suggested_target_cents"]
      assert_equal "1", response.parsed_body.dig("offer", "policy_version")
      assert_equal true, response.parsed_body.dig("offer", "late_start_acceptance_required")
      post "#{path}/enrollment", params: { participation_accepted: true, policy_version: "1", late_start_accepted: false, expected_acceptance_digest: savings_offer_digest }, headers: headers, as: :json
      assert_response :unprocessable_entity
      post "#{path}/enrollment", params: { participation_accepted: true, policy_version: "1", late_start_accepted: true, expected_acceptance_digest: savings_offer_digest }, headers: headers, as: :json
      assert_response :success
      assert_equal "2026-11-15", response.parsed_body.dig("record", "starts_on")
      assert_equal "2026-11-15", response.parsed_body.dig("challenge", "calendar", "local_today")
      assert_nil response.parsed_body.dig("challenge", "projection", "reported_cents")
    end
  end

  test "plan and actual reservation approvals return private exact cents and corrections leave prior progress until approved" do
    with_savings_runtime do
      savings_enroll
      post "#{path}/plan_drafts", params: { target_cents: 50_000, expected_plan_version_id: nil }, headers: headers, as: :json
      assert_response :success
      draft = response.parsed_body["record"]
      assert_nil response.parsed_body.dig("challenge", "accepted_plan")
      approve_plan(draft)
      assert_equal 50_000, response.parsed_body.dig("record", "target_cents")
      post "#{path}/entry_drafts", params: entry_input(49_999), headers: headers, as: :json
      assert_response :success
      draft = response.parsed_body["record"]
      assert_nil response.parsed_body.dig("challenge", "projection", "reported_cents")
      approve_entry(draft)
      assert_response :success
      version = response.parsed_body["record"]
      assert_equal 49_999, response.parsed_body.dig("challenge", "projection", "reported_cents")
      assert_equal false, response.parsed_body.dig("challenge", "projection", "achieved")
      assert_equal "not_linked", version["evidence_status"]
      assert_equal 0, version["evidence_supported_cents"]
      entry = SavingsEntry.find(version["savings_entry_id"])
      post "#{path}/entry_drafts", params: entry_input(50_000).merge(entry_id: entry.id, expected_version_id: version["id"], expected_entry_lock_version: entry.lock_version, reason: "Corrected amount"), headers: headers, as: :json
      draft = response.parsed_body["record"]
      assert_equal 49_999, response.parsed_body.dig("challenge", "projection", "reported_cents")
      approve_entry(draft)
      assert_equal 50_000, response.parsed_body.dig("challenge", "projection", "reported_cents")
      assert_equal true, response.parsed_body.dig("challenge", "projection", "achieved")
      assert_equal 0, @savings_household.goals.count
    end
  end

  test "same household partner cannot read or approve participant financial records and staff cannot select participant scope" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(10_000)
      partner = User.create!(clerk_id: "partner-#{SecureRandom.hex(8)}", email: "partner-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      @savings_household.household_memberships.create!(user: partner, role: "partner")
      @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
      get path, headers: headers(user: partner)
      assert_response :success
      assert_nil response.parsed_body["enrollment"]
      get "#{path}/entry_drafts", headers: headers(user: partner)
      assert_response :not_found
      post "#{path}/entry_drafts/#{draft.id}/approve", params: approval_input(draft), headers: headers(user: partner), as: :json
      assert_response :not_found
      get path, headers: headers(user: @savings_owner)
      assert_response :unprocessable_entity
      refute draft.reload.approved_version_id
    end
  end

  test "client cannot inject actor scope support reporting knownness or malformed cents and dates" do
    with_savings_runtime do
      savings_enroll
      malicious = [ { user_id: @savings_user.id }, { cohort_id: @savings_cohort.id }, { evidence_supported_cents: 1 }, { reporting_known: true }, { approved_at: Time.current.iso8601 }, { currency: "USD" }, { current_approved_version_id: 1 } ]
      malicious.each do |extra|
        post "#{path}/entry_drafts", params: entry_input(100).merge(extra), headers: headers, as: :json
        assert_response :unprocessable_entity
      end
      [ 1.5, "100", -100 ].each do |amount|
        post "#{path}/entry_drafts", params: entry_input(amount), headers: headers, as: :json
        assert_response :unprocessable_entity
      end
      post "#{path}/entry_drafts", params: entry_input(100).merge(effective_on: "2026-11-31"), headers: headers, as: :json
      assert_response :unprocessable_entity
      post "#{path}/entry_drafts", params: entry_input(100), headers: headers.except("Idempotency-Key"), as: :json
      assert_response :unprocessable_entity
      assert_equal 0, SavingsEntryVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 0, @savings_enrollment.savings_entries.count
    end
  end

  test "private idempotent replay reauthorizes membership release hold and rejects changed approval identity" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      key = "approve-#{SecureRandom.uuid}"
      post "#{path}/entry_drafts/#{draft.id}/approve", params: approval_input(draft), headers: headers(key: key), as: :json
      assert_response :success
      id = response.parsed_body.dig("record", "id")
      post "#{path}/entry_drafts/#{draft.id}/approve", params: approval_input(draft), headers: headers(key: key), as: :json
      assert_response :success
      assert response.parsed_body["replayed"]
      assert_equal id, response.parsed_body.dig("record", "id")
      post "#{path}/entry_drafts/#{draft.id}/approve", params: approval_input(draft).merge(accepted: false), headers: headers(key: key), as: :json
      assert_response :conflict
      @savings_cohort.update!(savings_challenge_release_hold: true)
      post "#{path}/entry_drafts/#{draft.id}/approve", params: approval_input(draft), headers: headers(key: key), as: :json
      assert_response :forbidden
      @savings_cohort.update!(savings_challenge_release_hold: false)
      @savings_membership.destroy!
      get path, headers: headers
      assert_response :unprocessable_entity
    end
  end

  test "all paged savings records identify the selected actor enrollment and cohort" do
    with_savings_runtime do
      savings_enroll
      %w[entries entry_versions entry_drafts plan_versions plan_drafts zero_attestations].each do |collection|
        get "#{path}/#{collection}", headers: headers
        assert_response :success
        body = response.parsed_body
        assert_equal @savings_enrollment.id, body.fetch("enrollment_id")
        assert_equal @savings_cohort.id, body.fetch("cohort_id")
        assert_equal({ "user_id" => @savings_user.id, "household_id" => @savings_household.id }, body.fetch("actor_scope"))
        assert_empty body.fetch("records")
      end
    end
  end

  test "private history and drafts use stable bounded cursor pagination with all rows accessible" do
    with_savings_runtime do
      savings_enroll
      103.times { savings_draft(100) }
      get "#{path}/entry_drafts", params: { limit: 100 }, headers: headers
      assert_response :success
      first = response.parsed_body["records"]
      cursor = response.parsed_body["next_cursor"]
      assert_equal 100, first.size
      get "#{path}/entry_drafts", params: { limit: 100, cursor: cursor }, headers: headers
      assert_response :success
      second = response.parsed_body["records"]
      assert_equal 3, second.size
      assert_nil response.parsed_body["next_cursor"]
      assert_equal 103, (first + second).map { |record| record["id"] }.uniq.size
      savings_zero
      get "#{path}/zero_attestations", headers: headers
      assert_response :success
      assert_equal 1, response.parsed_body["records"].size
      get "#{path}/entry_drafts", params: { limit: 101 }, headers: headers
      assert_response :unprocessable_entity
      get "#{path}/entry_drafts", params: { cursor: "1 OR 1=1" }, headers: headers
      assert_response :unprocessable_entity
    end
  end

  test "private status recovers an exact plan proposal without changing totals or trusting client scope" do
    with_savings_runtime do
      savings_enroll
      key = "recover-plan-#{SecureRandom.uuid}"
      post "#{path}/plan_drafts", params: { target_cents: 30_000, expected_plan_version_id: nil }, headers: headers(key: key), as: :json
      assert_response :success
      draft = response.parsed_body.fetch("record")
      get "#{path}/request_status", params: { review_action: "plan_stage" }, headers: headers(key: key)
      assert_response :success
      assert_equal "committed", response.parsed_body["state"]
      assert_equal draft["id"], response.parsed_body.dig("record", "id")
      assert_nil response.parsed_body.dig("challenge", "accepted_plan")
      assert_includes response.headers["Cache-Control"], "no-store"
      get "#{path}/request_status", params: { review_action: "entry_stage" }, headers: headers(key: key)
      assert_response :conflict
      get "#{path}/request_status", params: { review_action: "plan_stage" }, headers: headers(key: "unknown-request")
      assert_response :success
      assert_equal "unknown", response.parsed_body["state"]
      assert_equal @savings_cohort.id, response.parsed_body["cohort_id"]
      assert_equal 1, SavingsPlanDraft.where(savings_enrollment: @savings_enrollment).count
      @savings_cohort.update!(savings_challenge_release_hold: true)
      get "#{path}/request_status", params: { review_action: "plan_stage" }, headers: headers(key: key)
      assert_response :forbidden
    end
  end

  test "zero is an explicit elapsed-cutoff approval and cannot replace a nonzero approved result" do
    with_savings_runtime do
      savings_enroll
      input = { known_zero: true, cutoff_on: "2026-11-15", expected_enrollment_lock_version: @savings_enrollment.reload.lock_version }
      post "#{path}/zero_attestations", params: input.merge(cutoff_on: "2026-11-16"), headers: headers, as: :json
      assert_response :unprocessable_entity
      post "#{path}/zero_attestations", params: input.merge(known_zero: false), headers: headers, as: :json
      assert_response :unprocessable_entity
      post "#{path}/zero_attestations", params: input, headers: headers, as: :json
      assert_response :success
      assert_equal 0, response.parsed_body.dig("challenge", "projection", "reported_cents")
      assert_equal true, response.parsed_body.dig("challenge", "projection", "zero_attested")
      savings_approve(savings_draft(100))
      post "#{path}/zero_attestations", params: input.merge(expected_enrollment_lock_version: @savings_enrollment.reload.lock_version), headers: headers, as: :json
      assert_response :unprocessable_entity
      get path, headers: headers
      assert_equal 100, response.parsed_body.dig("projection", "reported_cents")
      assert_equal false, response.parsed_body.dig("projection", "zero_attested")
    end
  end

  private

  def path = "/api/v1/savings_challenge"

  def headers(user: @savings_user, key: SecureRandom.uuid)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s, "Idempotency-Key" => key }
  end

  def entry_input(amount)
    { signed_cents: amount, effective_on: "2026-11-15", funding_source: "new_money_reserved", expected_version_id: nil }
  end

  def approval_input(draft)
    draft = draft.attributes if draft.is_a?(SavingsEntryDraft)
    { accepted: true, expected_draft_lock_version: draft["lock_version"], expected_version_id: draft["base_version_id"], expected_entry_lock_version: draft["base_entry_lock_version"] }
  end

  def approve_entry(draft)
    post "#{path}/entry_drafts/#{draft['id']}/approve", params: approval_input(draft), headers: headers, as: :json
  end

  def approve_plan(draft)
    post "#{path}/plan_drafts/#{draft['id']}/approve", params: { accepted: true, expected_draft_lock_version: draft["lock_version"], expected_plan_version_id: draft["base_plan_version_id"] }, headers: headers, as: :json
    assert_response :success
  end
end
