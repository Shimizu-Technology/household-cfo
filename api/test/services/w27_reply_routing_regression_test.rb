require "test_helper"
class W27ReplyRoutingRegressionTest < ActiveSupport::TestCase
  test "cutback requests about work do not become spending analysis during an outage" do
    [ "how could i cut back hours at work", "where can we cut back weekend shifts", "how do i cut back on overtime" ].each do |message|
      refute SpendingPatterns::Answerer.matches?(message), message
    end
  end

  test "completed purchases after a proposed question remain separate" do
    [ "can i buy a $900 tv, i paid $20 for lunch today", "can i buy a $900 tv after i spent $20 on lunch" ].each do |message|
      refute HouseholdFinance::PurchaseQuestionText.proposed_purchase_only?(message), message
    end
  end

  test "amount writes do not change the requested year and unrelated balances stay out of month intent" do
    assert_equal Date.new(2026, 11, 1), HouseholdFinance::MiaMonthAnswer.question_date("change my rent to 2000, how much do i have left", today: Date.new(2026, 11, 7))
    [ "how much do i have in my bank account", "how much is left in my groceries", "how much can i spend on food this week", "do i have enough left this month for a $900 tv" ].each do |message|
      HouseholdFinance::ParticipantMessageReader::Current.reply_intent = { message: message, intent: "month_balance" }
      refute HouseholdFinance::MiaMonthAnswer.question?(message), message
    end
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "patterns never outrank purchases or essential care and accept direct commands" do
    [ "where can i cut back so i can get a $900 tv on my card", "should i buy a $900 tv? also whats my spending pattern", "how do i cut back my hours at work", "how do i cut back, i got laid off and cant pay rent" ].each do |message|
      refute SpendingPatterns::Answerer.matches?(message), message
    end
    [ "look at my spending patterns", "analyze my spending habits" ].each { |message| assert SpendingPatterns::Answerer.matches?(message), message }
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "unknown merchants never produce a zero spending bank dump" do
    user = User.create!(clerk_id: SecureRandom.uuid, email: "#{SecureRandom.uuid}@example.invalid", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    answer = HouseholdFinance::TransactionLookupAnswerer.new(household, "Follow-up to previous coaching topic. Prior Mia summary: You kept at it, and that effort matters. What helped you keep going? Current follow-up: did i spend anything on that").call
    refute_match(/synced bank activity|totaling \$0/, answer.to_s)
    unknown = HouseholdFinance::TransactionLookupAnswerer.new(household, "did i spend anything at Ross").call
    refute_match(/synced bank activity|totaling \$0/, unknown.to_s)
    assert_includes unknown, "does not establish"
  end
end
