class RetainMiaFinancialRestartLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :chat_messages, :financial_restart, :jsonb, default: {}, null: false
  end
end
