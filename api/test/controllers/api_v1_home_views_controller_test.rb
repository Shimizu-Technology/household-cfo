require "test_helper"

# What Home leads with is each person's own choice, saved to their account, over the
# program's default (month first).
class ApiV1HomeViewsControllerTest < ActionDispatch::IntegrationTest
  test "she saves year first for herself; her partner keeps the program's default; null goes back to it" do
    owner = create_user("home-view-owner@example.com")
    partner = create_user("home-view-partner@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(owner).household
    household.household_memberships.create!(user: partner, role: "partner")

    get "/api/v1/workspace", headers: auth_headers(owner)
    assert_response :success
    assert_equal({ "program" => "month", "chosen" => nil, "effective" => "month" }, response.parsed_body.dig("workspace", "home_view"))

    patch "/api/v1/home_view", params: { home_view: { chosen: "year" } }, headers: auth_headers(owner), as: :json
    assert_response :success
    assert_equal({ "program" => "month", "chosen" => "year", "effective" => "year" }, response.parsed_body.fetch("home_view"))
    get "/api/v1/workspace", headers: auth_headers(owner)
    assert_equal "year", response.parsed_body.dig("workspace", "home_view", "effective")
    get "/api/v1/workspace", headers: auth_headers(partner)
    assert_equal "month", response.parsed_body.dig("workspace", "home_view", "effective")

    patch "/api/v1/home_view", params: { home_view: { chosen: "week" } }, headers: auth_headers(owner), as: :json
    assert_response :unprocessable_entity
    assert_equal "year", household.household_memberships.find_by!(user: owner).home_view

    patch "/api/v1/home_view", params: { home_view: { chosen: nil } }, headers: auth_headers(owner), as: :json
    assert_response :success
    assert_equal "month", response.parsed_body.dig("home_view", "effective")
    assert_nil household.household_memberships.find_by!(user: owner).home_view
  end

  test "the database refuses any other value" do
    owner = create_user("home-view-check@example.com")
    membership = HouseholdFinance::WorkspaceResolver.new(owner).household.household_memberships.find_by!(user: owner)
    assert_raises(ActiveRecord::StatementInvalid) { membership.update_column(:home_view, "week") }
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
