require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1NaturalPurchaseReportsTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll; savings_plan }
  end
  teardown { travel_back }

  test "the QA framing and spoken cents produce one exact unreviewed challenge report without saved purchases" do
    messages = [
      [ "For today's check-in, I spent $12.34 at Payless on groceries today and bought nothing else. Please prepare one check-in card for me to review. Don't save these purchases until I approve.", [ [ 1234, "Payless" ] ] ],
      [ "I spent eighteen dollars and forty-seven cents at Payless this morning", [ [ 1847, "Payless" ] ] ],
      [ "I bought a $5 coffee at Starbucks and spent twelve dollars at Payless and bought nothing else", [ [ 500, "Starbucks" ], [ 1200, "Payless" ] ] ]
    ]
    messages.each_with_index do |(message, expected), index|
      assert_no_difference [ "HouseholdTransaction.count", "SavingsDailyPurchaseDraft.count", "SavingsDailyPurchaseVersion.count", "TransactionDraft.count" ] do
        post "/api/v1/mia/messages", params: { message: message, request_id: "natural-#{index}" }, headers: challenge_auth, as: :json
        assert_response :created
      end
      report = response.parsed_body.fetch("savings_intake")
      assert_equal "daily_report", report.fetch("kind")
      assert_equal expected, report.fetch("purchases").map { |row| [ row.fetch("amount_cents"), row.fetch("merchant") ] }
      assert_equal "unreviewed_input", report.fetch("approval_state")
      assert_equal false, report.fetch("counted")
      assert_nil response.parsed_body.fetch("transaction_draft")
    end
  end

  test "an incomplete report asks about the missing purchase without offering a partial card" do
    [ "I spent $8 at Shell and bought lunch at Kings", "I spent $8 at Shell and a backpack 12 at Kings" ].each_with_index do |message, index|
      assert_no_difference [ "HouseholdTransaction.count", "SavingsDailyPurchaseDraft.count", "TransactionDraft.count" ] do
        post "/api/v1/mia/messages", params: { message: message, request_id: "missing-price-#{index}" }, headers: challenge_auth, as: :json
        assert_response :created
      end
      assert_nil response.parsed_body.fetch("savings_intake")
      assert_equal "How much was the Kings purchase? Nothing was saved.", response.parsed_body.dig("assistant_message", "content")
    end
  end

  test "household spoken cents and multiple purchases create only pending reviews and no actuals" do
    user = User.create!(clerk_id: "natural_household", email: "natural-household@example.invalid", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    manager.create_category!(name: "Dining out", stack_key: "discretionary", monthly_amount: 200)
    manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 500)
    auth = { "Authorization" => "Bearer test_token_#{user.id}" }
    [ [ "I spent 18 dollars and 47 cents at Payless yesterday", [ [ 1847, "Payless", Date.new(2026, 11, 14) ] ] ],
      [ "I bought a $5 coffee at Starbucks and spent twelve dollars at Payless this morning", [ [ 500, "Starbucks", Date.new(2026, 11, 15) ], [ 1200, "Payless", Date.new(2026, 11, 15) ] ] ] ].each_with_index do |(message, expected), index|
      previous = household.transaction_drafts.ids
      assert_no_difference "HouseholdTransaction.count" do
        assert_difference "TransactionDraft.count", expected.length do
          post "/api/v1/mia/messages", params: { message: message, request_id: "household-natural-#{index}" }, headers: auth, as: :json
          assert_response :created
        end
      end
      drafts = household.transaction_drafts.where.not(id: previous).order(:id)
      assert_equal expected, drafts.pluck(:total_amount_cents, :merchant, :occurred_on)
      assert_equal [ "pending" ], drafts.pluck(:status).uniq
      assert_equal(index.zero? ? [ "Groceries" ] : [ "Dining out", "Groceries" ], drafts.includes(:budget_category).map { |draft| draft.budget_category&.name })
      expected.each { |_cents, merchant, _date| assert_includes response.parsed_body.dig("assistant_message", "content"), merchant }
      assert response.parsed_body.fetch("transaction_draft")
    end
  end

  private

  def challenge_auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
end
