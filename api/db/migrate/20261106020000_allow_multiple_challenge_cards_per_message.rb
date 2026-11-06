class AllowMultipleChallengeCardsPerMessage < ActiveRecord::Migration[8.1]
  def up
    remove_index :savings_chat_cards, :chat_message_id
    add_index :savings_chat_cards, :chat_message_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "A message may have multiple independently reviewed facts"
  end
end
