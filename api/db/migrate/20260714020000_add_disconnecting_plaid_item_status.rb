class AddDisconnectingPlaidItemStatus < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :plaid_items, name: "plaid_items_status"
    add_check_constraint :plaid_items,
                         "status IN ('active', 'update_required', 'error', 'disconnecting', 'disconnected')",
                         name: "plaid_items_status"
  end

  def down
    execute "UPDATE plaid_items SET status = 'active' WHERE status = 'disconnecting'"
    remove_check_constraint :plaid_items, name: "plaid_items_status"
    add_check_constraint :plaid_items,
                         "status IN ('active', 'update_required', 'error', 'disconnected')",
                         name: "plaid_items_status"
  end
end
