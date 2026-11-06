require "test_helper"

class ApiV1MiaReviewRoundTwoTest < ActionDispatch::IntegrationTest
  test "own saving request and separate purchase clauses preserve messages without financial writes" do
    travel_to Time.zone.local(2026, 11, 5, 12) do
      user = User.create!(clerk_id: "review2_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      HouseholdFinance::SetupUpdater.new(household, household_name: "Cruz", primary_goal: "Save", primary_income: "4500", fixed_expenses: "2100", flexible_spend: "900", debt_payment: "95").call
      headers = { "Authorization" => "Bearer test_token_#{user.id}" }
      [ "Can I afford to save $300?", "Can I buy a $300 stroller? I want to save for emergencies." ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message }, headers: headers, as: :json
        assert_response :created
        body = response.parsed_body
        answer = body.dig("assistant_message", "content")
        if index.zero?
          refute_match(/The \$.*purchase/i, answer)
        else
          assert_match(/\$300 stroller.*\$1,105/, answer)
        end
        assert_nil body["mia_action_draft"]
        assert_nil body["transaction_draft"]
        get "/api/v1/mia/messages", headers: headers
        assert_response :ok
        saved = response.parsed_body.fetch("messages").find { |entry| entry["id"] == body.dig("assistant_message", "id") }
        assert_equal answer, saved.fetch("content")
      end
      assert_empty household.household_transactions
      assert_empty household.transaction_drafts
      assert_empty household.mia_action_drafts
    end
  end
end
