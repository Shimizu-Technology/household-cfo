class AddExplicitChallengeLeaveCards < ActiveRecord::Migration[8.0]
  def up
    add_column :setup_support_requests, :leave_intent, :string
    add_check_constraint :setup_support_requests, "leave_intent IS NULL OR (reason = 'leave_challenge' AND leave_intent IN ('leave', 'pause'))", name: "setup_support_leave_intent"
    remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal', 'savings', 'leave')", name: "savings_chat_card_kind"
  end

  def down
    if select_value("SELECT COUNT(*) FROM savings_chat_cards WHERE kind = 'leave'").to_i.positive? || select_value("SELECT COUNT(*) FROM setup_support_requests WHERE leave_intent IS NOT NULL").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Leave cards and chosen intent must retain their meaning."
    end
    remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal', 'savings')", name: "savings_chat_card_kind"
    remove_check_constraint :setup_support_requests, name: "setup_support_leave_intent"
    remove_column :setup_support_requests, :leave_intent
  end
end
