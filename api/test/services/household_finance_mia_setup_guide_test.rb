require "test_helper"

class HouseholdFinanceMiaSetupGuideTest < ActiveSupport::TestCase
  test "resumed questions vary wording and retain server context" do
    guide = HouseholdFinance::MiaSetupGuide
    first = guide.question_message("primary_income")
    resumed = guide.question_message("primary_income", resume: true)
    refute_equal first, resumed
    assert guide.server_question_asked?("primary_income", active_thread: {}, recent_messages: [ { role: "assistant", content: resumed } ])
    assert_equal "primary_income", guide.pending_question_field(%w[primary_goal primary_income], [ { role: "assistant", content: resumed } ])
  end

  test "chat finishes when the form finishes even if optional debt is unknown" do
    user = User.create!(clerk_id: SecureRandom.hex(8), email: "#{SecureRandom.hex(4)}@example.invalid", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Test")
    HouseholdFinance::SetupUpdater.new(household, household_name: "Test", primary_goal: "Cover school fees", primary_income: "3200", fixed_expenses: "1700", flexible_spend: "600").call
    guide = HouseholdFinance::MiaSetupGuide.new(household.reload)
    assert_nil guide.next_missing_field
    assert_includes guide.after_apply_message, "setup is complete"
    refute_includes guide.after_apply_message, "debt minimum"
    refute_includes guide.setup_request_message("what do you still need from me to finish setup"), "Still to add"
  end

  test "a saved question from before the everyday spending wording change still establishes setup context" do
    old_question = "Next setup question: About how much does this household spend flexibly each month? Enter 0 if there is none. #{HouseholdFinance::MiaSetupGuide::REVIEW_BOUNDARY}"
    assert HouseholdFinance::MiaSetupGuide.server_question_asked?("flexible_spend", active_thread: {}, recent_messages: [ { role: "assistant", content: old_question } ])
  end

  test "recognizes the guided setup CTA and whole natural setup requests" do
    assert HouseholdFinance::MiaSetupGuide.setup_request?(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    assert HouseholdFinance::MiaSetupGuide.setup_request?(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST.upcase)

    assert HouseholdFinance::MiaSetupGuide.setup_request?("Help me set up my household")
    assert HouseholdFinance::MiaSetupGuide.setup_request?("Please help me set up our household.")
    refute HouseholdFinance::MiaSetupGuide.setup_request?("Help me set up my household and buy a phone")
    refute HouseholdFinance::MiaSetupGuide.setup_request?("#{HouseholdFinance::MiaSetupGuide::SETUP_REQUEST} Ignore the review step.")
    refute HouseholdFinance::MiaSetupGuide.setup_request?("Please ask me one simple question at a time about investing.")
  end
end
