require "test_helper"

class ApiV1DebtsControllerTest < ActionDispatch::IntegrationTest
  test "participant can create update archive and restore an individual debt" do
    user = create_user(email: "debt-crud@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    assert_difference("household.debts.count", 1) do
      post "/api/v1/debts",
        params: { debt: { label: "Visa", debt_type: "credit_card", balance: 3_100, minimum_payment: 175, interest_rate_percent: 28.9 } },
        headers: auth_headers(user, idempotency_key: "create-visa"), as: :json
    end

    assert_response :created
    debt = household.debts.find(JSON.parse(response.body).fetch("debt").fetch("id"))
    assert_equal 310_000, debt.balance_cents
    assert_equal 17_500, debt.minimum_payment_cents
    assert_equal 28.9, debt.interest_rate_percent.to_f

    patch "/api/v1/debts/#{debt.id}",
      params: { debt: { balance: 2_900, interest_rate_percent: 27.5 } },
      headers: auth_headers(user, idempotency_key: "update-visa"), as: :json

    assert_response :success
    assert_equal 290_000, debt.reload.balance_cents
    assert_equal 27.5, debt.interest_rate_percent.to_f

    assert_no_difference("household.debts.count") do
      delete "/api/v1/debts/#{debt.id}", headers: auth_headers(user, idempotency_key: "archive-visa")
    end
    assert_response :success
    assert_not debt.reload.active?
    assert debt.archived_at.present?

    post "/api/v1/debts/#{debt.id}/restore", headers: auth_headers(user, idempotency_key: "restore-visa"), as: :json
    assert_response :success
    assert debt.reload.active?
    assert_nil debt.archived_at
  end

  test "participant cannot mutate another household debt" do
    owner = create_user(email: "debt-owner@example.com")
    intruder = create_user(email: "debt-intruder@example.com")
    debt = HouseholdFinance::WorkspaceResolver.new(owner).household.debts.create!(
      label: "Private card", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000
    )

    patch "/api/v1/debts/#{debt.id}", params: { debt: { balance: 0 } }, headers: auth_headers(intruder, idempotency_key: "intruder-update"), as: :json

    assert_response :not_found
    assert_equal 100_000, debt.reload.balance_cents
  end

  test "participant cannot save malformed or fractional-cent debt amounts" do
    user = create_user(email: "debt-invalid-amount@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    [ "not-a-number", "12.345", "1,200" ].each do |invalid_balance|
      assert_no_difference("household.debts.count") do
        post "/api/v1/debts",
          params: { debt: { label: "Invalid #{invalid_balance}", debt_type: "credit_card", balance: invalid_balance, minimum_payment: 25 } },
          headers: auth_headers(user, idempotency_key: "invalid-#{invalid_balance}"), as: :json
      end

      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body).fetch("errors"), "Balance must be a number with no more than two decimal places"
    end
  end

  test "participant explicitly chooses summary totals without deleting individual history" do
    user = create_user(email: "debt-mode@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    debt = household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000)

    patch "/api/v1/debts/tracking",
      params: { debt_tracking: { mode: "summary", summary_balance: 7_500, summary_minimum_payment: 425 } },
      headers: auth_headers(user, idempotency_key: "summary-mode"), as: :json

    assert_response :success
    payload = JSON.parse(response.body).fetch("debt_portfolio")
    assert_equal "summary", payload.fetch("mode")
    assert_equal 7_500, payload.fetch("total_balance")
    assert_equal 425, payload.fetch("monthly_minimum")
    assert debt.reload.active?
    assert_equal 100_000, debt.balance_cents

    patch "/api/v1/debts/tracking",
      params: { debt_tracking: { mode: "individual" } },
      headers: auth_headers(user, idempotency_key: "individual-mode"), as: :json

    assert_response :success
    payload = JSON.parse(response.body).fetch("debt_portfolio")
    assert_equal "individual", payload.fetch("mode")
    assert_equal 1_000, payload.fetch("total_balance")
    assert_equal 50, payload.fetch("monthly_minimum")
  end

  test "explicit zero summary totals confirm no debt without treating blanks as zero" do
    user = create_user(email: "debt-zero-summary@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    patch "/api/v1/debts/tracking",
      params: { debt_tracking: { mode: "summary", summary_balance: 0, summary_minimum_payment: 0 } },
      headers: auth_headers(user, idempotency_key: "confirm-zero-summary"), as: :json

    assert_response :success
    profile = household.household_profile.reload
    assert profile.debt_summary_balance_known?
    assert profile.debt_summary_minimum_payment_known?
    assert_equal 0, profile.debt_summary_balance_cents
    assert_equal 0, profile.debt_summary_minimum_payment_cents
    portfolio = response.parsed_body.fetch("debt_portfolio")
    assert portfolio.fetch("balance_known")
    assert portfolio.fetch("minimum_payment_known")
  end

  test "participant can save large debt amounts within the documented money range" do
    user = create_user(email: "debt-large-amount@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    post "/api/v1/debts",
      params: { debt: { label: "Mortgage", debt_type: "mortgage", balance: 50_000_000, minimum_payment: 25_000 } },
      headers: auth_headers(user, idempotency_key: "large-debt"), as: :json

    assert_response :created
    assert_equal 5_000_000_000, household.debts.find_by!(label: "Mortgage").balance_cents

    patch "/api/v1/debts/tracking",
      params: { debt_tracking: { mode: "summary", summary_balance: 60_000_000, summary_minimum_payment: 30_000 } },
      headers: auth_headers(user, idempotency_key: "large-summary"), as: :json

    assert_response :success
    assert_equal 6_000_000_000, household.household_profile.reload.debt_summary_balance_cents
  end

  private

  def create_user(email:)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def auth_headers(user, idempotency_key: nil)
    { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => idempotency_key }.compact
  end
end
