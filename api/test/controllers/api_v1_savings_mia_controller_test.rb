require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1SavingsMiaControllerTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll; savings_plan; savings_approve(savings_draft(20_001)) }
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "challenge coaching uses approved savings and bypasses annual setup and financial writes" do
    assert_no_difference [ "BudgetYear.count", "HouseholdTransaction.count", "SavingsEntryVersion.count", "TransactionDraft.count" ] do
      post "/api/v1/mia/messages", params: { message: "How much savings progress do I have?", request_id: "savings-progress" }, headers: auth, as: :json
      assert_response :created
    end
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes answer, "$200.01"
    assert_includes answer, "$500.00"
    assert_includes answer, "90-day"
    assert_includes answer, "approved reported"
    assert_nil response.parsed_body.fetch("budget")
    assert_nil response.parsed_body.fetch("transaction_draft")
    count = ChatMessage.count
    post "/api/v1/mia/messages", params: { message: "How much savings progress do I have?", request_id: "savings-progress" }, headers: auth, as: :json
    assert_response :created
    assert_equal count, ChatMessage.count
  end

  test "debt free and optional feelings need no setup while hold blocks ordinary chat" do
    [ [ "I do not have credit cards", "without credit cards or debt" ], [ "I feel guilty", "leave feelings blank" ], [ "I bought lunch yesterday", "amount, where and date" ] ].each_with_index do |(message, expected), index|
      post "/api/v1/mia/messages", params: { message: message, request_id: "savings-topic-#{index}" }, headers: auth, as: :json
      assert_response :created
      assert_includes response.parsed_body.dig("assistant_message", "content"), expected
    end
    @savings_cohort.update!(savings_challenge_release_hold: true)
    assert_no_difference "ChatMessage.count" do
      post "/api/v1/mia/messages", params: { message: "How is my savings?", request_id: "held-chat" }, headers: auth, as: :json
      assert_response :forbidden
    end
  end

  test "chat prepares exact review input while amounts ambiguous future or unreserved reductions never count" do
    assert_no_difference [ "SavingsEntryDraft.count", "SavingsEntryVersion.count", "SavingsDailyPurchaseDraft.count", "HouseholdTransaction.count" ] do
      post "/api/v1/mia/messages", params: { message: "I spent $12.35 at Synthetic Cafe today", request_id: "chat-purchase" }, headers: auth, as: :json
      assert_response :created
      intake = response.parsed_body.fetch("savings_intake")
      assert_equal "purchase", intake.fetch("kind")
      assert_equal 1235, intake.fetch("amount_cents")
      assert_equal "2026-11-15", intake.fetch("effective_on")
      assert_equal "Synthetic Cafe", intake.fetch("merchant")
      refute intake.fetch("counted")
      [ "Could I save $20 today?", "I spent $20 and $30 today", "I saved $20 on 2026-11-16", "I spent $20 at Synthetic Cafe yesterday", "I have not yet saved $20 today", "I paid a credit card payment of $20 today" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "ambiguous-#{index}" }, headers: auth, as: :json
        assert_response :created
        assert_nil response.parsed_body.fetch("savings_intake")
      end
      post "/api/v1/mia/messages", params: { message: "I set aside $20.01 today", request_id: "chat-contribution" }, headers: auth, as: :json
      assert_response :created
      assert_equal 2001, response.parsed_body.dig("savings_intake", "signed_cents")
      assert response.parsed_body.dig("savings_intake", "new_money_confirmation_required")
    end
  end

  private
  def auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
end
