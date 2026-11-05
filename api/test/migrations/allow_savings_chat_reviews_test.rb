require "test_helper"
require_relative "../support/savings_daily_test_support"
require Rails.root.join("db/migrate/20261105010000_allow_savings_chat_reviews").to_s

class AllowSavingsChatReviewsTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport

  test "upgrade defers validation to a separate migration" do
    migration = AllowSavingsChatReviews.new
    connection = ApplicationRecord.connection
    connection.remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
    connection.add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal')", name: "savings_chat_card_kind"
    migration.migrate(:up)
    assert_equal false, validated?
    require Rails.root.join("db/migrate/20261105010001_validate_savings_chat_reviews").to_s
    ValidateSavingsChatReviews.new.migrate(:up)
    assert_equal true, validated?
  end

  test "rollback refuses existing savings cards without losing their review data" do
    setup_savings_context
    with_savings_runtime { savings_enroll }
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    message = session.chat_messages.create!(role: "assistant", content: "Review your savings", cohort: @savings_cohort, cohort_release: @savings_release)
    card = SavingsChatCard.create!(savings_enrollment: @savings_enrollment, chat_message: message, kind: "savings", input: { amount_cents: 2500 }, state: {})
    assert_raises(ActiveRecord::IrreversibleMigration) { AllowSavingsChatReviews.new.migrate(:down) }
    assert_equal "savings", card.reload.kind
    assert_equal 2500, card.input["amount_cents"]
  end

  private

  def validated?
    ApplicationRecord.connection.select_value("SELECT convalidated FROM pg_constraint WHERE conrelid = 'savings_chat_cards'::regclass AND conname = 'savings_chat_card_kind'")
  end
end
