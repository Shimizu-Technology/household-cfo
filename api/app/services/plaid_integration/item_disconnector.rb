module PlaidIntegration
  class ItemDisconnector
    def initialize(plaid_item, user:)
      @plaid_item = plaid_item
      @user = user
    end

    def call
      Client.safely do |client|
        client.item_remove(Plaid::ItemRemoveRequest.new(access_token: plaid_item.access_token))
      end
      ApplicationRecord.transaction do
        plaid_item.plaid_transactions.delete_all
        plaid_item.plaid_accounts.delete_all
        plaid_item.update!(access_token: nil, sync_cursor: nil, status: "disconnected", disconnected_at: Time.current, error_code: nil, error_message: nil)
        plaid_item.household.household_audit_events.create!(user: user, actor_type: "user", event_type: "plaid_item.disconnected", auditable_type: "PlaidItem", auditable_id: plaid_item.id, occurred_at: Time.current, metadata: { institution_name: plaid_item.institution_name })
      end
      plaid_item
    end

    private

    attr_reader :plaid_item, :user
  end
end
