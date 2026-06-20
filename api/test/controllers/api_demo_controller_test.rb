require "test_helper"

class ApiDemoControllerTest < ActionDispatch::IntegrationTest
  test "profile returns demo household profile" do
    get "/api/demo/profile"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Household CFO Demo Family", body.fetch("household").fetch("name")
    assert_equal "Mia", body.fetch("coach").fetch("name")
  end

  test "dashboard returns demo financial summary and accounts" do
    get "/api/demo/dashboard"

    assert_response :success
    body = JSON.parse(response.body)
    assert_operator body.fetch("summary").fetch("monthly_income"), :>, 0
    assert body.fetch("accounts").any?
    assert body.fetch("alerts").any?
  end

  test "budget returns expense stack categories" do
    get "/api/demo/budget"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Expense Stack", body.fetch("framework")
    labels = body.fetch("stacks").map { |stack| stack.fetch("label") }
    assert_includes labels, "Non-discretionary"
    assert_includes labels, "Sinking Fund — Expected"
    assert_includes labels, "Sinking Fund — Unexpected"
  end

  test "wealth returns simplified net worth snapshot" do
    get "/api/demo/wealth"

    assert_response :success
    body = JSON.parse(response.body)
    assert_operator body.fetch("summary").fetch("net_worth"), :>, 0
    assert body.fetch("milestones").any?
  end

  test "optionality returns choices with readiness scores" do
    get "/api/demo/optionality"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Founder transition", body.fetch("scenario")
    assert body.fetch("choices").all? { |choice| choice.key?("readiness_score") }
  end

  test "cfo filter returns strategic spending recommendations" do
    get "/api/demo/cfo-filter"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "CFO Filter", body.fetch("framework")
    assert body.fetch("decisions").any?
  end

  test "mia messages returns demo conversation" do
    get "/api/demo/mia/messages"

    assert_response :success
    body = JSON.parse(response.body)
    assert body.fetch("messages").any? { |message| message.fetch("role") == "assistant" }
  end

  test "mia chat post returns a response without requiring external llm" do
    post "/api/demo/mia/messages", params: { message: "Can I take the leap?" }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "user", body.fetch("user_message").fetch("role")
    assert_equal "assistant", body.fetch("assistant_message").fetch("role")
    assert_includes body.fetch("assistant_message").fetch("content"), "Mia"
  end
end
