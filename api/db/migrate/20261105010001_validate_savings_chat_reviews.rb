class ValidateSavingsChatReviews < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :savings_chat_cards, name: "savings_chat_card_kind"
  end

  def down
    # Validation does not change which values are allowed.
  end
end
