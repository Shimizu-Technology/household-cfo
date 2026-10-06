require "test_helper"
require_relative "../support/savings_debt_test_support"

class ApiV1FinancialRestartsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDebtTestSupport
  setup do
    setup_savings_context
    @user, @household = @savings_user, @savings_household
  end

  test "ordinary Mia recognizes complete reset and Everything continuations without provider or writes" do
    @savings_membership.destroy!
    assert_no_difference [ "Debt.count", "IncomeSource.count", "FinancialRestartReview.count" ] do
      [ "So these aren't my actual numbers - are you able to reset it all and we can start from scratch?", "Everything", "All the information that I have" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "restart-loop-#{index}" }, headers: auth, as: :json
        assert_response :created
        assert_equal "review_available", response.parsed_body.dig("financial_restart", "state")
        assert_equal true, response.parsed_body.dig("assistant_message", "financial_restart", "available")
        assert_includes response.parsed_body.dig("assistant_message", "content"), "Nothing changes until"
        refute_includes response.parsed_body.dig("assistant_message", "content"), "What specific"
      end
    end
    get "/api/v1/mia/messages", headers: auth
    assert_response :success
    assert response.body.include?("review_available")
  end

  test "BOG reset routing preserves challenge progress evidence optional terms and source provenance" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_evidence_operations do
        savings_enroll
        savings_plan
        entry = savings_approve(savings_draft(20_000))
        source, document = evidence_source
        evidence_attach(entry, [ evidence_proof(source, amount: 15_000) ])
        household_debt = @household.debts.create!(label: "Fake Visa", debt_type: "credit_card", balance_cents: 30_000, minimum_payment_cents: 1_000)
        candidate = SavingsChallenge::Debt::HouseholdMapping.new(@household).candidate(household_debt)
        draft = savings_run("debt.stage", { terms: debt_terms, expected_version_id: nil, expected_head_lock_version: 0,
          household_debt_mapping: { household_debt_id: household_debt.id, fingerprint: candidate[:fingerprint] } }).subject
        terms = debt_approve(draft)
        before = savings_projection.slice(:reported_cents, :evidence_supported_cents)
        3.times do |index|
          message = [ "Please reset all my information and start over", "Everything", "All the information that I have" ][index]
          post "/api/v1/mia/messages", params: { message: message, request_id: "bog-restart-#{index}" }, headers: auth, as: :json
          assert_response :created
          assert_equal "review_available", response.parsed_body.dig("financial_restart", "state")
        end
        post "/api/v1/financial_restart/preview", headers: auth, as: :json
        assert_response :created
        id = response.parsed_body.dig("financial_restart", "review", "id")
        post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
        assert_response :success
        assert_equal 1, response.parsed_body.dig("financial_restart", "financial_generation")
        assert_equal before, savings_projection.slice(:reported_cents, :evidence_supported_cents)
        assert_equal 15_000, savings_projection[:evidence_supported_cents]
        assert_equal terms.terms, terms.reload.terms
        assert_equal document.id, FinancialDocumentImport.find(document.id).id
        assert_equal source.id, SourceReviewVersion.find(source.id).id
        assert_equal household_debt.id, terms.household_debt.id
        assert_empty @household.reload.debts
        assert debt_read[:cards].first[:household_terms_changed]
      end
    end
  end

  test "stale financial writes reject but privacy controls remain available and apply status is exact" do
    @savings_membership.destroy!
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    id = response.parsed_body.dig("financial_restart", "review", "id")
    post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.financial_generation
    post "/api/v1/income_sources", params: { income_source: { label: "Stale", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth, as: :json
    assert_response :conflict
    assert_equal "financial_generation_stale", response.parsed_body["code"]
    post "/api/v1/income_sources", params: { income_source: { label: "Fresh", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth.merge("X-Financial-Generation" => "1"), as: :json
    assert_response :created
    get "/api/v1/financial_restart/status", params: { review_id: id }, headers: auth
    assert_response :success
    assert_equal id, response.parsed_body.dig("financial_restart", "latest_review", "id")
    assert_equal "applied", response.parsed_body.dig("financial_restart", "latest_review", "status")
    post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.income_sources.count
    assert_equal 1, @household.financial_generation
  end

  private
  def auth
    { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }.tap { |headers| headers["X-Cohort-Id"] = @savings_cohort.id.to_s unless @savings_membership.destroyed? }
  end
end
