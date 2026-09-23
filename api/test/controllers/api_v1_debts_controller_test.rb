require "test_helper"

class ApiV1DebtsControllerTest < ActionDispatch::IntegrationTest
  test "participant can create update and remove an individual debt" do
    user = create_user(email: "debt-crud@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    assert_difference("household.debts.count", 1) do
      post "/api/v1/debts",
        params: { debt: { label: "Visa", debt_type: "credit_card", balance: 3_100, minimum_payment: 175, interest_rate_percent: 28.9 } },
        headers: auth_headers(user), as: :json
    end

    assert_response :created
    debt = household.debts.find(JSON.parse(response.body).fetch("debt").fetch("id"))
    assert_equal 310_000, debt.balance_cents
    assert_equal 17_500, debt.minimum_payment_cents
    assert_equal 28.9, debt.interest_rate_percent.to_f

    patch "/api/v1/debts/#{debt.id}",
      params: { debt: { balance: 2_900, interest_rate_percent: 27.5 } },
      headers: auth_headers(user), as: :json

    assert_response :success
    assert_equal 290_000, debt.reload.balance_cents
    assert_equal 27.5, debt.interest_rate_percent.to_f

    assert_difference("household.debts.count", -1) do
      delete "/api/v1/debts/#{debt.id}", headers: auth_headers(user)
    end
    assert_response :no_content
  end

  test "participant cannot mutate another household debt" do
    owner = create_user(email: "debt-owner@example.com")
    intruder = create_user(email: "debt-intruder@example.com")
    debt = HouseholdFinance::WorkspaceResolver.new(owner).household.debts.create!(
      label: "Private card", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 5_000
    )

    patch "/api/v1/debts/#{debt.id}", params: { debt: { balance: 0 } }, headers: auth_headers(intruder), as: :json

    assert_response :not_found
    assert_equal 100_000, debt.reload.balance_cents
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

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
