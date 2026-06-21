require "test_helper"

class ApiV1WorkspaceControllerTest < ActionDispatch::IntegrationTest
  test "workspace creates an empty household for an authenticated participant" do
    user = create_user(email: "participant@example.com")

    get "/api/v1/workspace", headers: auth_headers(user)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "real", body.fetch("workspace").fetch("mode")
    assert_equal "participant's Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 0, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
  end

  test "workspace setup saves real household numbers and recalculates dashboard" do
    user = create_user(email: "mel@example.com", first_name: "Mel")

    patch "/api/v1/workspace/setup",
          params: {
            workspace: {
              household_name: "Mendiola Household",
              primary_goal: "Decide if the purse is in the cards.",
              primary_income: 8_000,
              business_income: 1_200,
              fixed_expenses: 4_500,
              flexible_spend: 1_300,
              expected_sinking_fund: 500,
              unexpected_sinking_fund: 300,
              emergency_fund: 18_000,
              other_assets: 12_000,
              credit_card_debt: 7_000,
              debt_payment: 700,
              target_runway_months: 6
            }
          },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Mendiola Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 9_200, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
    assert_equal 7_300, body.fetch("budget").fetch("total_monthly_outflow")
    assert_equal 1_900, body.fetch("budget").fetch("baseline_surplus")
    assert_equal 2.5, body.fetch("dashboard").fetch("summary").fetch("runway_months")
  end

  test "workspace setup rejects negative income values" do
    user = create_user(email: "negative-income@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: -500 } },
          headers: auth_headers(user),
          as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body.fetch("errors").any? { |error| error.include?("Amount cents") }
    assert_empty user.households.first.income_sources
  end

  test "workspace setup updates transition goal instead of duplicating it" do
    user = create_user(email: "goal@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "Leave my job safely" } },
          headers: auth_headers(user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_goal: "Buy a rental property" } },
          headers: auth_headers(user),
          as: :json

    assert_response :success
    household = user.households.first
    transition_goals = household.goals.where(goal_type: "transition")
    assert_equal 1, transition_goals.count
    assert_equal "Buy a rental property", transition_goals.first.label
  end

  test "workspaces are isolated per user" do
    first_user = create_user(email: "first@example.com")
    second_user = create_user(email: "second@example.com")

    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "First Household", primary_income: 5_000 } },
          headers: auth_headers(first_user),
          as: :json
    patch "/api/v1/workspace/setup",
          params: { workspace: { household_name: "Second Household", primary_income: 9_000 } },
          headers: auth_headers(second_user),
          as: :json

    get "/api/v1/workspace", headers: auth_headers(first_user)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "First Household", body.fetch("profile").fetch("household").fetch("name")
    assert_equal 5_000, body.fetch("dashboard").fetch("summary").fetch("monthly_income")
  end

  test "mia chat uses real workspace context and persists messages" do
    user = create_user(email: "mia@example.com")
    patch "/api/v1/workspace/setup",
          params: { workspace: { primary_income: 8_000, fixed_expenses: 4_000, emergency_fund: 8_000 } },
          headers: auth_headers(user),
          as: :json

    post "/api/v1/mia/messages",
         params: { message: "Can I buy the purse?" },
         headers: auth_headers(user),
         as: :json

    assert_response :created
    content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    assert_includes content, "Lanya"
    assert_includes content, "che’lu"

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    messages = JSON.parse(response.body).fetch("messages")
    assert_equal [ "user", "assistant" ], messages.map { |message| message.fetch("role") }
  end

  test "mia chat history can be cleared" do
    user = create_user(email: "clear@example.com")
    post "/api/v1/mia/messages", params: { message: "test" }, headers: auth_headers(user), as: :json

    delete "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :no_content

    get "/api/v1/mia/messages", headers: auth_headers(user)

    assert_response :success
    assert_empty JSON.parse(response.body).fetch("messages")
  end

  private

  def create_user(email:, first_name: nil, role: "participant")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      first_name: first_name,
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
