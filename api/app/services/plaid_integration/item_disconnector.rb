module PlaidIntegration
  class ItemDisconnector
    ALREADY_REMOVED_CODES = %w[ITEM_NOT_FOUND].freeze

    def initialize(plaid_item, user:)
      @plaid_item = plaid_item
      @user = user
    end

    def call
      previously_disconnecting = mark_disconnecting!
      begin
        Client.safely do |client|
          client.item_remove(Plaid::ItemRemoveRequest.new(access_token: plaid_item.access_token))
        end
      rescue Error => e
        if previously_disconnecting
          raise unless e.code.in?(ALREADY_REMOVED_CODES)
        else
          restore_status!
          raise
        end
      end
      clear_local_data!
      plaid_item
    end

    private

    attr_reader :plaid_item, :user, :original_status

    def mark_disconnecting!
      was_disconnecting = false
      plaid_item.with_lock do
        raise Error, "This bank connection is already disconnected" if plaid_item.status == "disconnected"

        was_disconnecting = plaid_item.status == "disconnecting"
        @original_status = plaid_item.status
        plaid_item.update!(status: "disconnecting") unless was_disconnecting
      end
      was_disconnecting
    end

    def restore_status!
      plaid_item.update!(status: original_status || "active") if plaid_item.reload.status == "disconnecting"
    end

    def clear_local_data!
      ApplicationRecord.transaction do
        plaid_item.lock!
        plaid_item.plaid_transactions.delete_all
        plaid_item.plaid_accounts.delete_all
        plaid_item.update!(access_token: nil, sync_cursor: nil, status: "disconnected", disconnected_at: Time.current, error_code: nil, error_message: nil)
        plaid_item.household.household_audit_events.create!(user: user, actor_type: "user", event_type: "plaid_item.disconnected", auditable_type: "PlaidItem", auditable_id: plaid_item.id, occurred_at: Time.current, metadata: { institution_name: plaid_item.institution_name })
      end
    end
  end
end
