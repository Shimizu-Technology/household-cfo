require "test_helper"

class ApiV1GoalsControllerTest < ActionDispatch::IntegrationTest
  test "participant creates updates archives and restores a tracked goal" do
    user = create_user("goals-crud@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    post "/api/v1/goals", params: { goal: { label: "Family trip", goal_type: "travel", target_amount: nil, current_amount: 0, target_on: "2027-06-01" } }, headers: headers(user, "create"), as: :json
    assert_response :created
    goal = household.goals.tracked.find(response.parsed_body.dig("goal", "id"))
    assert_not goal.target_amount_known?
    assert goal.current_amount_known?
    assert_nil response.parsed_body.dig("goal", "target_amount")
    assert_equal 0, response.parsed_body.dig("goal", "current_amount")

    patch "/api/v1/goals/#{goal.id}", params: { goal: { target_amount: 5_000, current_amount: 250 } }, headers: headers(user, "update"), as: :json
    assert_response :success
    assert_equal 500_000, goal.reload.target_amount_cents
    assert_equal 25_000, goal.current_amount_cents

    delete "/api/v1/goals/#{goal.id}", headers: headers(user, "archive")
    assert_response :success
    assert_not goal.reload.active?
    post "/api/v1/goals/#{goal.id}/restore", headers: headers(user, "restore"), as: :json
    assert_response :success
    assert goal.reload.active?
  end

  test "participant cannot mutate another household goal or a policy goal" do
    owner = create_user("goal-owner@example.com")
    intruder = create_user("goal-intruder@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(owner).household
    tracked = household.goals.create!(label: "Home", goal_type: "home", record_kind: "tracked")
    policy = household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6)

    patch "/api/v1/goals/#{tracked.id}", params: { goal: { current_amount: 1 } }, headers: headers(intruder, "intrude"), as: :json
    assert_response :not_found
    patch "/api/v1/goals/#{policy.id}", params: { goal: { current_amount: 1 } }, headers: headers(owner, "policy"), as: :json
    assert_response :not_found
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def headers(user, key)
    { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => key }
  end
end
