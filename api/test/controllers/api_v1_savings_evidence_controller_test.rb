require "test_helper"
require_relative "../support/savings_evidence_test_support"

class ApiV1SavingsEvidenceControllerTest < ActionDispatch::IntegrationTest
  include SavingsEvidenceTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_evidence_operations do
      savings_enroll
      @entry = savings_approve(savings_draft(20_000))
      @source, @document = evidence_source
    end
  end
  teardown { travel_back }

  test "partial reviewed evidence is a subset and same-key recovery never adds a contribution" do
    get "#{path}/candidates", params: { entry_version_id: @entry.id }, headers: headers
    assert_response :success
    candidate = response.parsed_body.fetch("records").sole
    assert_equal @source.id, candidate.fetch("source_review_version_id")
    assert_equal 20_000, candidate.fetch("available_cents")
    assert_equal @source.digest, candidate.fetch("expected_source_digest")
    assert_equal 1, candidate.fetch("movement_legs").length
    assert_equal @source.signed_amount_cents, candidate.fetch("movement_legs").sole["signed_amount_cents"]
    assert_equal @document.filename, candidate.fetch("movement_legs").sole["filename"]
    key = "attach-#{SecureRandom.uuid}"
    input = evidence_input(@entry, [ evidence_proof(@source, amount: 15_000) ])
    2.times do
      post "#{path}/actions/attach", params: input, headers: headers(key: key), as: :json
      assert_response :success
    end
    version_id = response.parsed_body.dig("record", "id")
    assert response.parsed_body.fetch("replayed")
    display = response.parsed_body.dig("record", "proof_display").sole
    assert_equal @source.merchant, display["merchant"]
    assert_equal @document.filename, display["filename"]
    assert_equal 15_000, display["amount_cents"]
    assert_not display.to_json.match?(/s3_key|household_id|version_id|digest/)
    assert_equal 20_000, savings_projection[:reported_cents]
    assert_equal 15_000, savings_projection[:evidence_supported_cents]
    assert_equal 0, @entry.reload.evidence_supported_cents
    get "#{path}/request_status", params: { review_action: "attach", entry_version_id: @entry.id }, headers: headers(key: key)
    assert_response :success
    assert_equal "committed", response.parsed_body.fetch("state")
    assert_equal version_id, response.parsed_body.dig("record", "id")
    assert_includes response.headers["Cache-Control"], "no-store"
    get path, params: { entry_version_id: @entry.id }, headers: headers
    assert_response :success
    assert_equal 15_000, response.parsed_body.dig("entry", "evidence_supported_cents")
    assert_equal 1, response.parsed_body.fetch("records").size
    post "#{path}/actions/attach", params: input, headers: headers, as: :json
    assert_response :conflict
    assert_equal 1, SavingsEvidenceVersion.where(savings_enrollment: @savings_enrollment).count
    with_evidence_operations { savings_approve(savings_draft(-10_000, funding: "withdrawal")) }
    assert_equal 10_000, savings_projection[:reported_cents]
    assert_equal 5_000, savings_projection[:evidence_supported_cents]
    execution = @savings_household.household_operation_executions.find_by!(operation_key: "savings.evidence.attach")
    assert_empty execution.normalized_input
    assert_empty execution.after_snapshot
  end

  test "current source changes invalidate support and explicit revoke releases capacity without changing reported savings" do
    with_evidence_operations { evidence_attach(@entry, [ evidence_proof(@source, amount: 10_000) ]) }
    with_evidence_operations do
      evidence_source_review(@source.financial_source_event, identity: @source.source_account_identity_version, amount: 19_000, type: "income", on: @entry.effective_on)
    end
    get path, params: { entry_version_id: @entry.id }, headers: headers
    assert_response :success
    assert_equal "stale", response.parsed_body.dig("entry", "evidence_status")
    assert_equal 0, response.parsed_body.dig("entry", "evidence_supported_cents")
    head = SavingsEvidenceAllocation.find_by!(savings_entry_version: @entry)
    input = { entry_version_id: @entry.id, expected_evidence_version_id: head.current_version_id, expected_head_lock_version: head.lock_version,
      accepted: true, reason: "Withdraw stale proof after correction" }
    post "#{path}/actions/revoke", params: input, headers: headers, as: :json
    assert_response :success
    assert_equal "revoked", response.parsed_body.dig("record", "state")
    assert_equal 20_000, savings_projection[:reported_cents]
    assert_equal 0, savings_projection[:evidence_supported_cents]
    assert_equal 2, head.reload.savings_evidence_versions.count
  end

  test "approved facts remain usable after raw erasure and refunds and old source facts are absent from candidates" do
    with_evidence_operations do
      evidence_source(1000, type: "refund")
      evidence_source(1000, on: @savings_enrollment.starts_on - 1)
    end
    @document.update!(source_deleted_at: Time.current, s3_key: nil, status: "source_deleted")
    FinancialDocuments::SourceEvidenceEraser.call(@document)
    get "#{path}/candidates", params: { entry_version_id: @entry.id }, headers: headers
    assert_response :success
    rows = response.parsed_body.fetch("records")
    assert_equal [ @source.id ], rows.pluck("source_review_version_id")
    assert_equal false, rows.sole.fetch("source_available")
    post "#{path}/actions/attach", params: evidence_input(@entry, [ evidence_proof(@source, amount: 10_000) ]), headers: headers, as: :json
    assert_response :success
    assert_equal 10_000, savings_projection[:evidence_supported_cents]
  end

  test "partner staff foreign entry and caller-selected calculation scope cannot reveal or approve participant evidence" do
    partner = User.create!(clerk_id: SecureRandom.uuid, email: "evidence-partner-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @savings_household.household_memberships.create!(user: partner, role: "partner")
    @savings_cohort.cohort_memberships.create!(user: partner, role: "participant")
    with_evidence_operations do
      HouseholdFinance::Operations::Runner.new(@savings_household, user: partner).run(operation_key: "savings.enrollment.accept",
        input: { cohort_id: @savings_cohort.id, participation_accepted: true, policy_version: "1", late_start_accepted: true, expected_acceptance_digest: savings_offer_digest(user: partner) }, idempotency_key: SecureRandom.uuid)
    end
    get path, params: { entry_version_id: @entry.id }, headers: headers(user: partner)
    assert_response :not_found
    get path, params: { entry_version_id: @entry.id }, headers: headers(user: @savings_owner)
    assert_response :unprocessable_entity
    assert_equal "cohort_selection_invalid", response.parsed_body["code"]
    input = evidence_input(@entry, [ evidence_proof(@source, amount: 10_000) ])
    post "#{path}/actions/attach", params: input.merge(approval_sequence: 0), headers: headers, as: :json
    assert_response :unprocessable_entity
    post "#{path}/actions/attach", params: input.merge(cohort_id: @savings_cohort.id), headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_empty SavingsEvidenceVersion.where(savings_enrollment: @savings_enrollment)
    @savings_cohort.update!(savings_challenge_release_hold: true)
    get path, params: { entry_version_id: @entry.id }, headers: headers
    assert_response :forbidden
  end

  test "paging keeps later valid movements reachable when ungrouped transfers fill the first page" do
    with_evidence_operations do
      50.times { evidence_source(1000, type: "transfer") }
      2.times { evidence_source(1000) }
    end
    get "#{path}/candidates", params: { entry_version_id: @entry.id }, headers: headers
    assert_response :success
    first = response.parsed_body
    assert_equal [ @source.id ], first.fetch("records").pluck("source_review_version_id")
    assert first["next_cursor"]
    get "#{path}/candidates", params: { entry_version_id: @entry.id, cursor: first["next_cursor"] }, headers: headers
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("records").size
    assert_nil response.parsed_body["next_cursor"]
    assert response.parsed_body.fetch("records").all? { |row| row["movement_kind"] == "reviewed_income" }
  end

  private
  def path = "/api/v1/savings_challenge/evidence"
  def headers(user: @savings_user, key: SecureRandom.uuid)
    { "Authorization" => "Bearer test_token_#{user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s, "Idempotency-Key" => key }
  end
end
