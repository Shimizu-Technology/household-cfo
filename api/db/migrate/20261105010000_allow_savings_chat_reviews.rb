class AllowSavingsChatReviews < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind", expression: "kind IN ('daily_report', 'goal')"
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal', 'savings')", name: "savings_chat_card_kind"
  end
end
