class AddAutoConfirmTrustedMerchantsToPlaidItems < ActiveRecord::Migration[8.1]
  def change
    add_column :plaid_items, :auto_confirm_trusted_merchants, :boolean, default: false, null: false
  end
end
