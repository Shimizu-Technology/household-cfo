class AllowSavingsChatReviews < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal', 'savings')", name: "savings_chat_card_kind", validate: false
  end

  def down
    # Pending cards contain participant input. Never discard or relabel it just
    # to restore an older application schema.
    if select_value("SELECT EXISTS (SELECT 1 FROM savings_chat_cards WHERE kind = 'savings')")
      raise ActiveRecord::IrreversibleMigration, "Savings review cards exist. Preserve and review them before rolling back."
    end
    remove_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal')", name: "savings_chat_card_kind", validate: false
  end
end
